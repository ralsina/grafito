# src/ai/request.cr
#
# Normalized AI request type that works with any provider.
# Providers transform this into their specific format.

module Grafito::AI
  # Normalized AI request that works with any provider.
  # Providers transform this into their specific format.
  struct Request
    # Priority name to numeric string mapping
    PRIORITY_MAP = {
      "emerg"     => "0",
      "emergency" => "0",
      "alert"     => "1",
      "crit"      => "2",
      "critical"  => "2",
      "err"       => "3",
      "error"     => "3",
      "warning"   => "4",
      "warn"      => "4",
      "notice"    => "5",
      "info"      => "6",
      "debug"     => "7",
    }
    # The system prompt sets the AI's persona and behavior
    getter system_prompt : String

    # The user's actual question or request
    getter user_prompt : String

    # Maximum tokens to generate in response
    getter max_tokens : Int32

    # Randomness: 0.0 = deterministic, 1.0 = creative
    getter temperature : Float64

    def initialize(
      @system_prompt : String,
      @user_prompt : String,
      @max_tokens : Int32 = 1024,
      @temperature : Float64 = 0.7,
    ) : Nil
    end

    # Convenience constructor for log analysis use case.
    # Priority should be "0"-"7" or the formatted name (emerg, alert, crit, err, warning, notice, info, debug)
    def self.for_log_analysis(context : String, priority : String = "6", prompt : String? = nil) : self
      system_prompt = build_system_prompt(priority)
      user_prompt = build_user_prompt(priority, prompt)

      new(
        system_prompt: system_prompt,
        user_prompt: "#{user_prompt}\n\nLog Context:\n#{context}",
        max_tokens: 1024,
        temperature: 0.7
      )
    end

    # Build system prompt based on log priority
    private def self.build_system_prompt(priority : String) : String
      base = "You are a helpful AI assistant specializing in system log analysis."

      formatting = <<-FORMAT

        Format your response using simple markdown for readability:
        - Use **bold** for emphasis on key terms
        - Use `backticks` for commands, file paths, and config values
        - Use ## for section headers (not #)
        - Use - for bullet lists
        - Keep responses concise and scannable
        - Use blank lines between sections

        Example response format:

        ## Summary
        The service failed to start due to a **missing configuration file**.

        ## Likely Causes
        - Configuration file at `/etc/myservice/config.yaml` was deleted
        - **Permission denied** - service user cannot read the file
        - Path misconfiguration in the systemd unit

        ## Suggested Fix
        Check if the config exists and is readable:
        `ls -la /etc/myservice/`

        If missing, restore from backup or recreate the default config.
        FORMAT

      priority_context = case normalize_priority(priority)
                         when "0", "1", "2" # emerg, alert, crit
                           "This is a CRITICAL system event requiring immediate attention. " \
                           "Focus on impact assessment, immediate remediation steps, and escalation recommendations."
                         when "3" # err
                           "Provide clear explanations of errors with practical solutions and prevention strategies."
                         when "4" # warning
                           "Analyze warnings to identify potential issues before they become errors. Focus on proactive measures."
                         when "5" # notice
                           "Explain notable system events and their significance. These are normal but noteworthy occurrences."
                         when "6" # info
                           "Provide context about informational messages and what system activity they represent."
                         when "7" # debug
                           "Explain debug-level details for troubleshooting purposes. Focus on technical specifics."
                         else
                           "Provide clear, concise explanations with practical insights."
                         end

      "#{base} #{priority_context}#{formatting}"
    end

    # Build user prompt based on log priority
    private def self.build_user_prompt(priority : String, custom_prompt : String?) : String
      return custom_prompt if custom_prompt

      case normalize_priority(priority)
      when "0", "1", "2" # emerg, alert, crit
        "Please analyze this CRITICAL log entry. What happened? What's the immediate impact? What actions should be taken RIGHT NOW?"
      when "3" # err
        "Please explain the error in the highlighted log entry. Focus on what the error means, potential causes, and suggested solutions."
      when "4" # warning
        "Please explain this warning. What might cause it? Should I be concerned? What preventive actions could help?"
      when "5" # notice
        "Please explain this notice. What does it indicate about the system? Is any action needed?"
      when "6" # info
        "Please explain this informational message. What system activity does it represent?"
      when "7" # debug
        "Please explain this debug message. What technical details does it reveal for troubleshooting?"
      else
        "Please explain this log entry. What does it mean and is any action needed?"
      end
    end

    # Normalize priority to numeric string (0-7)
    private def self.normalize_priority(priority : String) : String
      normalized = priority.downcase.strip
      PRIORITY_MAP[normalized]? || normalized
    end
  end
end
