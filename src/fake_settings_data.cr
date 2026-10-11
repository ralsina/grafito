# # Fake settings (demo builds)
#
# In-memory stand-in for the settings store on `-Ddemo_mode` builds:
# the public demo must never read or write the host's settings.json.
# Starts "onboarded" with no credentials so the demo shows the plain
# settings view, not the onboarding wizard.

module FakeSettings
  @@settings : SettingsStore::Settings = SettingsStore::Settings.new(onboarded: true)

  def self.load : SettingsStore::Settings
    @@settings
  end

  def self.save(settings : SettingsStore::Settings) : Nil
    @@settings = settings
  end

  def self.reset : Nil
    @@settings = SettingsStore::Settings.new(onboarded: true)
  end
end
