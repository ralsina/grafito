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

    # Prior conversation turns about this same request (iterative
    # refinement). Each entry is {"role" => "user"|"assistant",
    # "content" => String}, in chronological order, ending with the
    # user's latest message. Providers that support multi-turn
    # conversations send these as real messages; others may render them
    # into the prompt as a transcript.
    getter history : Array(Hash(String, String))

    # The base analysis request is replayed before the history, so a
    # leading user-role history message would produce two consecutive
    # user turns (which the Anthropic API rejects and every provider
    # handles oddly). Merge it into the base user prompt instead — the
    # user's words are preserved and the roles alternate.
    def user_prompt_with_leading_history : String
      first = history.first?
      if first && first["role"] == "user"
        "#{user_prompt}\n\n---\n\nFollow-up from the user: #{first["content"]}"
      else
        user_prompt
      end
    end

    # History with the merged leading user message removed; the
    # remaining turns alternate assistant/user as the client sent them.
    def alternating_history : Array(Hash(String, String))
      if (first = history.first?) && first["role"] == "user"
        history[1..]
      else
        history
      end
    end

    def initialize(
      @system_prompt : String,
      @user_prompt : String,
      @max_tokens : Int32 = 1024,
      @temperature : Float64 = 0.7,
      history : Array(Hash(String, String)) = [] of Hash(String, String),
    ) : Nil
      @history = history
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

    # Convenience constructor for the dashboard's "explain this unit"
    # use case. `unit_report` is a plain-text summary of the unit's
    # state plus recent journal excerpts, assembled by the caller.
    def self.for_unit_diagnosis(unit_report : String) : self
      system_prompt = <<-SYSTEM
        You are a systemd expert assistant embedded in a server dashboard
        for a homelab administrator. You will receive the current state of
        one systemd unit and excerpts of its recent journal entries.

        Your job:
        - Explain what the unit does and why it is in its current state.
        - If it is failed or degraded: the likely causes based on the
          journal excerpts, and concrete remediation commands.
        - If it is healthy: whether anything in the recent entries needs
          attention. Keep it short.
        - Use only the provided information; say so when it is not
          enough to reach a conclusion.

        Format your response using simple markdown for readability:
        - Use ## for section headers (not #)
        - Use - for bullet lists
        - Use `backticks` for commands, file paths and unit names
        - Keep it concise and scannable
        SYSTEM
      new(
        system_prompt: system_prompt,
        user_prompt: "Here is the unit report:\n\n#{unit_report}\n\nExplain this unit's situation.",
        max_tokens: 1024,
        temperature: 0.5,
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

      priority_context = case priority_bucket(priority)
                         when :critical
                           "This is a CRITICAL system event requiring immediate attention. " \
                           "Focus on impact assessment, immediate remediation steps, and escalation recommendations."
                         when :error
                           "Provide clear explanations of errors with practical solutions and prevention strategies."
                         when :warning
                           "Analyze warnings to identify potential issues before they become errors. Focus on proactive measures."
                         when :notice
                           "Explain notable system events and their significance. These are normal but noteworthy occurrences."
                         when :info
                           "Provide context about informational messages and what system activity they represent."
                         when :debug
                           "Explain debug-level details for troubleshooting purposes. Focus on technical specifics."
                         else
                           "Provide clear, concise explanations with practical insights."
                         end
      "#{base} #{priority_context}#{formatting}"
    end

    # Collapse a normalized priority into the coarse buckets the prompt
    # texts branch on, so the system and user prompt builders can never
    # drift apart.
    private def self.priority_bucket(priority : String) : Symbol
      case normalize_priority(priority)
      when "0", "1", "2" then :critical
      when "3"           then :error
      when "4"           then :warning
      when "5"           then :notice
      when "6"           then :info
      when "7"           then :debug
      else                    :unknown
      end
    end

    # Build user prompt based on log priority
    private def self.build_user_prompt(priority : String, custom_prompt : String?) : String
      return custom_prompt if custom_prompt

      case priority_bucket(priority)
      when :critical
        "Please analyze this CRITICAL log entry. What happened? What's the immediate impact? What actions should be taken RIGHT NOW?"
      when :error
        "Please explain the error in the highlighted log entry. Focus on what the error means, potential causes, and suggested solutions."
      when :warning
        "Please explain this warning. What might cause it? Should I be concerned? What preventive actions could help?"
      when :notice
        "Please explain this notice. What does it indicate about the system? Is any action needed?"
      when :info
        "Please explain this informational message. What system activity does it represent?"
      when :debug
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
