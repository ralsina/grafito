# # Fake homepage data
#
# A deterministic homepage config for demo builds (`-Dfake_journal`),
# the same idea as the fake journal, systemd and compose data: the
# page shows its full shape — several groups, every icon style, a
# weather widget — without a config file on disk.
#
# Status dots are fixed by URL so the demo always shows a mix of up
# and down services without probing anything over the network; the
# weather widget calls the live Open-Meteo API and quietly shows its
# "unavailable" state when offline.

require "./homepage_config"

module FakeHomepageData
  CONFIG_YAML = <<-YAML
    title: Demo Homelab

    weather:
      latitude: -34.9
      longitude: -56.16
      location: Montevideo

    groups:
      - name: Media
        services:
          - name: Jellyfin
            url: https://jellyfin.demo.ralsina.me
            description: Movies and series
            icon: play_circle
            check: true
          - name: Navidrome
            url: https://music.demo.ralsina.me
            description: Music streaming
            icon: library_music
            check: true
      - name: Productivity
        services:
          - name: Nextcloud
            url: https://cloud.demo.ralsina.me
            description: Files, calendar and contacts
            icon: cloud
            check: true
          - name: Vaultwarden
            url: https://vault.demo.ralsina.me
            description: Password manager
            icon: 🔐
      - name: Automation
        services:
          - name: Home Assistant
            url: https://ha.demo.ralsina.me
            description: House controls
            icon: home
            check: true
          - name: Gitea
            url: https://git.demo.ralsina.me
            description: Code hosting
            icon: https://raw.githubusercontent.com/go-gitea/gitea/main/assets/logo.svg
            check: true
    YAML

  def self.config : HomepageConfig::Config
    HomepageConfig::Config.from_yaml(CONFIG_YAML)
  end

  # One unreachable service (the music one) so the down state is
  # visible; everything else reports up.
  def self.statuses : Hash(String, Bool)
    config.groups.flat_map(&.services).select(&.check?).to_h do |service|
      {service.url, service.name != "Navidrome"}
    end
  end
end
