module CucumberStatistics
  class Formatter

    TEST_HOOK_NAMES_TO_IGNORE = ['Before hook', 'After hook']
    POSSIBLE_STATUSES = ['passed', 'failed', 'pending', 'skipped', 'undefined']

    def initialize(step_mother, io, options)
      @step_mother = step_mother
      @io = io
      @options = options

      @overall_statistics = OverallStatistics.new
      @step_statistics = StepStatistics.new
      @scenario_statistics = ScenarioStatistics.new
      @feature_statistics = FeatureStatistics.new
      @unused_steps = UnusedSteps.new
      @tracker = FeatureTracker.create
      @deferred_before_test_steps = []
      @deferred_after_test_steps = []
      @scenario_tags = {}
    end

    #----------------------------------------------------
    # Step callbacks
    #----------------------------------------------------
    def before_test_step(test_step)
      @step_start_time = Time.now if TEST_HOOK_NAMES_TO_IGNORE.include?(test_step.to_s)
    end

    def before_step_result(*args)
      @step_duration = Time.now - @step_start_time
    end

    def after_step_result(keyword, step_match, multiline_arg, status, exception, source_indent, background, file_colon_line)
      step_definition = step_match.step_definition.nil? ? step_match.name : step_match.step_definition
      if !step_definition.instance_of?(String) # nil if it's from a scenario outline
        @step_statistics.record step_definition.expression, @step_duration, file_colon_line
      else
        @step_statistics.record step_definition, @step_duration, file_colon_line
      end
    end


    #----------------------------------------------------
    # Feature Element callbacks
    #----------------------------------------------------
    def before_feature_element(feature_element)
      @scenario_outline = feature_element.instance_of?(Cucumber::Core::Ast::ScenarioOutline)
      @scenario_name = ''
      @scenario_file_colon_line = ''
      @scenario_start_time = Time.now
    end

    def after_feature_element(feature_element)
      s_duration = 0
      @step_mother.steps.each { |s| s_duration = s_duration.to_f + (s.duration.nanoseconds.to_f/1000000000).round(2) }
      @scenario_duration = s_duration
      @scenario_statistics.record @scenario_name, @scenario_duration, @scenario_file_colon_line
    end

    #----------------------------------------------------
    # Feature callbacks
    #----------------------------------------------------
    def before_feature(feature)
      @feature_name = ''
      @feature_file = ''
      @feature_start_time = Time.now
    end

    #----------------------------------------------------
    # Overall callbacks
    #----------------------------------------------------
    #def before_feature(feature)
    #end
    def scenario_name(keyword, name, file_colon_line, source_indent)
      scenario_name = (name.nil? || name == "") ? "Unnamed scenario" : name.gsub(/\n/, " ")
      @scenario_outline ? @scenario_outline_name = scenario_name : @tracker.scenario_name = scenario_name
      @overall_statistics.scenario_count_inc
      @scenario_name = scenario_name
      @scenario_file_colon_line = file_colon_line
    end

    def feature_name(keyword, name)
      @overall_statistics.feature_count_inc
      @feature_name = name
    end

    def after_step(step)
      @overall_statistics.step_count_inc
    end

    def after_feature(feature)
      @feature_file = feature.location.to_s
      @feature_duration = Time.now - @feature_start_time
      @feature_statistics.record @feature_name, @feature_duration, @feature_file
    end

    def before_features(features)
      @overall_statistics.start_time = Time.now
    end

    def after_features(features)

      @overall_statistics.end_time = Time.now

      # gather unused steps
      @step_mother.unmatched_step_definitions.each do |step_definition|
        @unused_steps.record step_definition.regexp_source, step_definition.location.to_s
      end

      @step_statistics.calculate

      Renderer.render_combined_statistics @step_statistics, @scenario_statistics, @feature_statistics, @overall_statistics
    end

    def before_feature(feature)
      feature_identifier = ENV['FEATURE_IDENTIFIER'] && "#{ENV['FEATURE_IDENTIFIER']} - "
      @tracker.feature_name = "#{feature_identifier}#{feature.name.gsub(/\n/, " ")}"
    end

    def before_examples(*args)
      @header_row = true
    end

    def before_scenario(scenario)
      # not used now, but keeping for later.
    end

    # Start the test for normal scenarios
    def before_steps(steps)
      if !@scenario_outline  
        start_test
      end
    end

    # Stop the test for normal scenarios
    def after_steps(steps)
      if !@scenario_outline
        @result = test_result(steps)
      end
    end

    def after_scenario(scenario)
      @result[:status] = cucumber_status_to_allure_status(scenario.status)
      stop_test(@result)
    end

    def after_feature_element(feature_element)
      after_scenario(feature_element)
    end

    # Start the test for scenario examples
    def before_table_row(table_row)
      if @scenario_outline && !@header_row && !@in_multiline_arg
        @tracker.scenario_name = "#{@scenario_outline_name}: #{table_row.values.join(' | ')}"
        start_test
      end
    end

    # Stop the test for scenario examples 
    def after_table_row(table_row)
      unless @multiline_arg
        if @scenario_outline && !@header_row 
          @result = test_result(table_row)
          stop_test(@result)
        end
        @header_row = false
      end
    end
    
    def before_test_step(test_step)
      if !TEST_HOOK_NAMES_TO_IGNORE.include?(test_step.to_s) 
        if @tracker.scenario_name
          step_location =  test_step.location.lines.first.to_s
          step_name = test_step.to_s
          @tracker.step_id = "#{@tracker.feature_name}-#{@tracker.scenario_name}-#{step_name}-#{step_location}"
          @tracker.step_name = step_name
          start_step
        else
          @deferred_before_test_steps << {:step => test_step, :timestamp => Time.now}
        end        
      end
    end
    
    def after_test_step(test_step, result)
      if test_step.to_s == 'Before hook'
        if (!@before_hook_exception) && result.methods.include?(:exception)
          @before_hook_exception = result.exception
        end
      elsif test_step.to_s != 'After hook'
        if @tracker.scenario_name
          status = step_status(result)
          stop_step(status)
        else
          @deferred_after_test_steps << {:step => test_step, :result => result, :timestamp => Time.now}
        end
      end
    end
    
    def before_multiline_arg(multiline_arg)
      @in_multiline_arg = true
      # For background steps defer multiline attachment
      if @tracker.scenario_name.nil?
        @deferred_before_test_steps[-1].merge!({:multiline_arg => multiline_arg})
      else
        attach_multiline_arg_to_file(multiline_arg)
      end
    end

    def after_multiline_arg(multiline_arg)
      @in_multiline_arg = false
    end

    def embed(src, mime_type, label)
      file = File.open(src)
      file.close
      attach_file(label, file)
    end

    private

    def remove_tag_prefix(tag, prefix)
      tag.gsub(prefix,'')
    end
    
    def step_status(result)
      POSSIBLE_STATUSES.each do |status|
        return cucumber_status_to_allure_status(status) if result.send("#{status}?")
      end
    end
    
    def test_result(result)
      status = cucumber_status_to_allure_status(result.status)
      if @before_hook_exception
        exception = @before_hook_exception
      else
        exception = status == 'failed' && result.exception.nil? ? Exception.new("Some steps were undefined") : result.exception
      end
      if exception 
        return {:status => status, :exception => exception}
      else
        return {:status => status}
      end
    end

    def cucumber_status_to_allure_status(status)
      case status.to_s
        when "undefined"
          return "broken"
        when "skipped"
          return "canceled"
        else
          return status.to_s
      end
    end
    
    def attach_multiline_arg_to_file(multiline_arg)
      dir = File.expand_path(AllureCucumber::Config.output_dir)
      out_file = "#{dir}/#{UUID.new.generate}.txt"     
      File.open(out_file, "w+") { |file| file.write(multiline_arg.to_s.gsub(/\e\[(\d+)(;\d+)*m/,'')) }
      attach_file("multiline_arg", File.open(out_file))
    end

    def start_test
      if @tracker.scenario_name
        @scenario_tags[:feature] = @tracker.feature_name
        @scenario_tags[:story]   = @tracker.scenario_name
        # AllureRubyAdaptorApi::Builder.start_test(@tracker.feature_name, @tracker.scenario_name, @scenario_tags)
        post_deferred_steps
      end
    end

    def post_deferred_steps
      @deferred_before_test_steps.size.times do |index|
        step_location =  @deferred_before_test_steps[index][:step].location.lines.first.to_s
        step_name = @deferred_before_test_steps[index][:step].name
        @tracker.step_id = "#{@tracker.feature_name}-#{@tracker.scenario_name}-#{step_name}-#{step_location}"
        @tracker.step_name = step_name
        start_step
        multiline_arg = @deferred_before_test_steps[index][:multiline_arg]
        attach_multiline_arg_to_file(multiline_arg) if multiline_arg
        if index < @deferred_after_test_steps.size
          result = step_status(@deferred_after_test_steps[index][:result])
          stop_step(result)
        end
      end
    end
    
    def stop_test(result)
      if @deferred_before_test_steps != []
        result[:started_at] = @deferred_before_test_steps[0][:timestamp]
      end
      if @tracker.scenario_name
        # AllureRubyAdaptorApi::Builder.stop_test(@tracker.feature_name, @tracker.scenario_name, result)
        @tracker.scenario_name = nil
        @deferred_before_test_steps = []
        @deferred_after_test_steps = []
        @scenario_tags = {}
        @before_hook_exception = nil
      end
    end

    def start_step(step_name = @tracker.step_name, step_id = @tracker.step_id)
      # AllureRubyAdaptorApi::Builder.start_step(@tracker.feature_name, @tracker.scenario_name, step_name, step_id)
    end

    def stop_step(status, step_name = @tracker.step_name, step_id = @tracker.step_id)
      # AllureRubyAdaptorApi::Builder.stop_step(@tracker.feature_name, @tracker.scenario_name, step_name, step_id, status)
    end
  end
end
