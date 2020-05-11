module CucumberStatistics
  class Formatter

    TEST_HOOK_NAMES_TO_IGNORE = ['Before hook', 'After hook']

    def initialize(step_mother, io, options)
      @step_mother = step_mother
      @io = io
      @options = options

      @overall_statistics = OverallStatistics.new
      @step_statistics = StepStatistics.new
      @scenario_statistics = ScenarioStatistics.new
      @feature_statistics = FeatureStatistics.new
      @unused_steps = UnusedSteps.new
    end

    #----------------------------------------------------
    # Step callbacks
    #----------------------------------------------------
    def before_test_step(test_step)
      @step_start_time = Time.now
    end

    def after_test_step(test_step, result)
      step_name = test_step.to_s
      if !TEST_HOOK_NAMES_TO_IGNORE.include?(step_name)
        step_location = test_step.location.file + ':' + test_step.location.line.to_s
        duration = (result.duration.nanoseconds/1000000000.to_f).round(2)
        @step_statistics.record step_name, duration, step_location
      end
    end

    def before_step_result(*args)
      @step_duration = Time.now - @step_start_time
    end

    def after_step_result(keyword, step_match, multiline_arg, status, exception, source_indent, background, file_colon_line)
      step_definition = step_match.step_definition.nil? ? step_match.name : step_match.step_definition
      if !step_definition.instance_of?(String) # nil if it's from a scenario outline
        #@step_statistics.record step_definition.expression, @step_duration, file_colon_line
      else
        #@step_statistics.record step_definition, @step_duration, file_colon_line
      end
    end

    def after_test_case(test_case, result)
      if @scenario_outline
        @scenario_name = test_case.source[1].name + ' | ' + test_case.source.last.values.join(' | ') + ' |'
      else
        @scenario_name = test_case.name
      end
      @scenario_duration = (result.duration.nanoseconds/1000000000.to_f).round(2) rescue 0.0
      @scenario_file_colon_line = test_case.location.file + ':' + test_case.location.line.to_s
      @scenario_statistics.record @scenario_name, @scenario_duration, @scenario_file_colon_line
    end

    #----------------------------------------------------
    # Feature Element callbacks
    #----------------------------------------------------
    def before_feature_element(feature_element)
      @scenario_name = ''
      @scenario_file_colon_line = ''
      @scenario_start_time = Time.now
      @scenario_outline = feature_element.instance_of?(Cucumber::Core::Ast::ScenarioOutline)
    end

    def after_feature_element(feature_element)
      # s_duration = 0
      # @step_mother.steps.each { |s| s_duration = s_duration.to_f + (s.duration.nanoseconds.to_f/1000000000).round(2) }
      # @scenario_duration = s_duration
      # @scenario_statistics.record @scenario_name, @scenario_duration, @scenario_file_colon_line
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
      @overall_statistics.scenario_count_inc
      @scenario_name = name
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
  end
end
