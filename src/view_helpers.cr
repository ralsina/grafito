# # View helpers
#
# Markup shared by the dashboard, compose and process views: the
# summary card, the tag pill and the action-error panel. The views
# include this module (#62); view-specific color mappings stay in
# the views, since "running" means docker to one and systemd to
# another.

require "html_builder"

module ViewHelpers
  extend self

  # One summary card, using the log view's `.stat` styling.
  def card(label : String, value : String, warn : Bool = false) : String
    HTML.build do
      div(class: "stat") do
        span(class: "stat-label") { text label }
        span(class: warn ? "stat-value stat-error" : "stat-value") do
          text value
        end
      end
    end
  end

  # A state value as a pill, colored by the caller's semantic choice
  # (ok/warn/err/info/debug/muted).
  def pill(value : String, color : String) : String
    HTML.build do
      span(class: "tag tag-#{color}") do
        text value
      end
    end
  end

  # A failed action as an error block for the sidebar's Detail tab.
  def action_error_fragment(action : String, target : String, message : String) : String
    HTML.build do
      div(class: "service-panel service-panel-error") do
        tag("h4") do
          text "#{action[0].upcase}#{action[1..]} failed: #{target}"
        end
        tag("pre", class: "service-panel-error-message") do
          text message
        end
      end
    end
  end

  # The base path as a prefix for URLs ("", or "/subdir" with no
  # trailing slash) — the one idiom for base-path-aware URLs.
  def base_prefix : String
    Grafito.base_path == "/" ? "" : Grafito.base_path
  end
end
