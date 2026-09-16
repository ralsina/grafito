# src/gotify/rules.cr
#
# Built-in alert rules evaluated on every metrics sample. Four rules
# cover the common "my server is unhappy" cases:
#
# * a systemd unit entered the failed state,
# * a previously failed unit recovered (the event operators wait for),
# * the error rate (priority <= 3 journal entries) spiked,
# * disk usage crossed the configured threshold.
#
# Rules debounce themselves: once a rule fires it stays quiet for
# DEBOUNCE minutes even if the condition persists, so a stuck unit or a
# full disk produces one notification, not one per sample.

require "mutex"
require "set"
require "time"

require "./config"

module Grafito::Gotify
  record Alert, rule : String, title : String, message : String

  class Rules
    # How long a fired rule stays quiet.
    DEBOUNCE = 10.minutes

    @last_fired = Hash(String, Time).new
    @previously_failed = Set(String).new
    @mutex = Mutex.new

    def initialize(
      @disk_threshold_pct : Float64 = Config.disk_threshold_pct,
      @errors_per_min_threshold : Float64 = Config.errors_per_min_threshold,
    )
    end

    # Evaluates all rules against one sample. Returns the alerts that
    # should be sent right now (respecting debounce), oldest first.
    def evaluate(
      disk_used_pct : Float64,
      failed_units : Array(String),
      errors_per_min : Float64,
      now : Time = Time.utc,
    ) : Array(Alert)
      alerts = Array(Alert).new

      # Recovery: units that were failed on the previous sample and are
      # not failed anymore. Fires once per recovery (the unit leaves
      # the failed set, so there is nothing to debounce against).
      current_failed = failed_units.to_set
      @mutex.synchronize do
        (@previously_failed - current_failed).to_a.sort.each do |unit|
          alerts << Alert.new(
            rule: "unit_recovered_#{unit}",
            title: "Service recovered",
            message: "#{unit} is no longer in a failed state.",
          )
        end
        @previously_failed = current_failed
      end

      unless failed_units.empty?
        alerts << Alert.new(
          rule: "unit_failed",
          title: "Service failed",
          message: "Units in failed state: #{failed_units.join(", ")}",
        )
      end

      if errors_per_min >= @errors_per_min_threshold
        alerts << Alert.new(
          rule: "error_rate",
          title: "Error rate high",
          message: "#{errors_per_min.round(1)} errors/min in the journal (threshold: #{@errors_per_min_threshold.to_i})",
        )
      end

      if disk_used_pct >= @disk_threshold_pct
        alerts << Alert.new(
          rule: "disk_full",
          title: "Disk almost full",
          message: "Root filesystem at #{disk_used_pct.round(1)}% (threshold: #{@disk_threshold_pct.to_i}%)",
        )
      end

      # Filter through the debounce table so a persistent condition
      # notifies once, not on every sample.
      @mutex.synchronize do
        alerts.select do |alert|
          last = @last_fired[alert.rule]?
          next false if last && (now - last) < DEBOUNCE
          @last_fired[alert.rule] = now
          true
        end
      end
    end

    # Test/ops hook: forget all debounce state.
    def reset : Nil
      @mutex.synchronize { @last_fired.clear }
    end
  end
end
