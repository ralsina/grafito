# src/gotify/rules.cr
#
# Built-in alert rules evaluated on every metrics sample:
#
# * a systemd unit entered the failed state,
# * a previously failed unit recovered (the event operators wait for),
# * the error rate (priority <= 3 journal entries) spiked,
# * disk usage crossed the configured threshold,
# * swap usage crossed the configured threshold — with its own
#   recovery notification when it drops back under it,
# * the kernel OOM killer terminated a process.
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
    @swap_was_high = false
    @mutex = Mutex.new

    def initialize(
      @disk_threshold_pct : Float64 = Config.disk_threshold_pct,
      @errors_per_min_threshold : Float64 = Config.errors_per_min_threshold,
      @swap_threshold_pct : Float64 = Config.swap_threshold_pct,
    )
    end

    # Evaluates all rules against one sample. Returns the alerts that
    # should be sent right now (respecting debounce), oldest first.
    # swap_used_pct is nil when the machine runs without swap; oom_kills
    # counts kernel OOM kills since the previous sample.
    def evaluate(
      disk_used_pct : Float64,
      failed_units : Array(String),
      errors_per_min : Float64,
      swap_used_pct : Float64? = nil,
      oom_kills : Int32 = 0,
      now : Time = Time.utc,
    ) : Array(Alert)
      alerts = Array(Alert).new

      # Recovery events first: the unit left the failed set, or swap
      # usage dropped back under its threshold.
      alerts += unit_recovery_alerts(failed_units)
      if swap_recovery = swap_recovery_alert(swap_used_pct)
        alerts << swap_recovery
      end
      alerts += condition_alerts(disk_used_pct, failed_units, errors_per_min, swap_used_pct, oom_kills)

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

    # The condition rules: something is wrong right now, on this
    # sample. Debounce still keeps repeated firings quiet.
    private def condition_alerts(
      disk_used_pct : Float64,
      failed_units : Array(String),
      errors_per_min : Float64,
      swap_used_pct : Float64?,
      oom_kills : Int32,
    ) : Array(Alert)
      alerts = Array(Alert).new

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

      if swap_used_pct && swap_used_pct >= @swap_threshold_pct
        alerts << Alert.new(
          rule: "swap_high",
          title: "Swap almost full",
          message: "Swap at #{swap_used_pct.round(1)}% (threshold: #{@swap_threshold_pct.to_i}%): memory pressure or a runaway process.",
        )
      end

      if oom_kills > 0
        alerts << Alert.new(
          rule: "oom_kill",
          title: "Out of memory",
          message: "The kernel OOM killer terminated #{oom_kills} #{oom_kills == 1 ? "process" : "processes"} within the last minute.",
        )
      end

      alerts
    end

    # Units that were failed on the previous sample and are not failed
    # anymore. Fires once per recovery (the unit leaves the failed set,
    # so there is nothing to debounce against).
    private def unit_recovery_alerts(failed_units : Array(String)) : Array(Alert)
      current_failed = failed_units.to_set
      @mutex.synchronize do
        recovered = (@previously_failed - current_failed).to_a.sort.map do |unit|
          Alert.new(
            rule: "unit_recovered_#{unit}",
            title: "Service recovered",
            message: "#{unit} is no longer in a failed state.",
          )
        end
        @previously_failed = current_failed
        recovered
      end
    end

    # Swap recovery: usage was over the threshold on a previous sample
    # and is back under it now. Nil readings update nothing — a missing
    # value is not evidence of recovery either way. The recovery is
    # itself debounced, like every rule.
    private def swap_recovery_alert(swap_used_pct : Float64?) : Alert?
      swap_high = swap_used_pct.try(&.>= @swap_threshold_pct) || false
      @mutex.synchronize do
        alert = nil
        if swap_used_pct
          if @swap_was_high && !swap_high
            alert = Alert.new(
              rule: "swap_recovered",
              title: "Swap recovered",
              message: "Swap usage back to #{swap_used_pct.round(1)}% (threshold: #{@swap_threshold_pct.to_i}%).",
            )
          end
          @swap_was_high = swap_high
        end
        alert
      end
    end

    # Test/ops hook: forget all debounce state.
    def reset : Nil
      @mutex.synchronize { @last_fired.clear }
    end
  end
end
