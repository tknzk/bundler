# frozen_string_literal: true
require "uri"

module Bundler
  class Settings
    BOOL_KEYS = %w(frozen cache_all no_prune disable_local_branch_check disable_shared_gems ignore_messages gem.mit gem.coc silence_root_warning no_install).freeze
    NUMBER_KEYS = %w(retry timeout redirect ssl_verify_mode).freeze
    DEFAULT_CONFIG = { :retry => 3, :timeout => 10, :redirect => 5 }.freeze

    def initialize(root = nil)
      @root          = root
      @local_config  = load_config(local_config_file)
      @global_config = load_config(global_config_file)
    end

    def [](name)
      key = key_for(name)
      value = (@local_config[key] || ENV[key] || @global_config[key] || DEFAULT_CONFIG[name])

      case
      when value.nil?
        nil
      when is_bool(name) || value == "false"
        to_bool(value)
      when is_num(name)
        value.to_i
      else
        value
      end
    end

    def []=(key, value)
      local_config_file || raise(GemfileNotFound, "Could not locate Gemfile")
      set_key(key, value, @local_config, local_config_file)
    end

    alias_method :set_local, :[]=

    def delete(key)
      @local_config.delete(key_for(key))
    end

    def set_global(key, value)
      set_key(key, value, @global_config, global_config_file)
    end

    def all
      env_keys = ENV.keys.select {|k| k =~ /BUNDLE_.*/ }

      keys = @global_config.keys | @local_config.keys | env_keys

      keys.map do |key|
        key.sub(/^BUNDLE_/, "").gsub(/__/, ".").downcase
      end
    end

    def local_overrides
      repos = {}
      all.each do |k|
        repos[$'] = self[k] if k =~ /^local\./
      end
      repos
    end

    def mirror_for(uri)
      uri = URI(uri.to_s) unless uri.is_a?(URI)
      gem_mirrors.for(uri.to_s).uri
    end

    def credentials_for(uri)
      self[uri.to_s] || self[uri.host]
    end

    def gem_mirrors
      all.inject(Mirrors.new) do |mirrors, k|
        mirrors.parse(k, self[k]) if k =~ /^mirror\./
        mirrors
      end
    end

    def locations(key)
      key = key_for(key)
      locations = {}
      locations[:local]  = @local_config[key] if @local_config.key?(key)
      locations[:env]    = ENV[key] if ENV[key]
      locations[:global] = @global_config[key] if @global_config.key?(key)
      locations[:default] = DEFAULT_CONFIG[key] if DEFAULT_CONFIG.key?(key)
      locations
    end

    def pretty_values_for(exposed_key)
      key = key_for(exposed_key)

      locations = []
      if @local_config.key?(key)
        locations << "Set for your local app (#{local_config_file}): #{@local_config[key].inspect}"
      end

      if value = ENV[key]
        locations << "Set via #{key}: #{value.inspect}"
      end

      if @global_config.key?(key)
        locations << "Set for the current user (#{global_config_file}): #{@global_config[key].inspect}"
      end

      return ["You have not configured a value for `#{exposed_key}`"] if locations.empty?
      locations
    end

    def without=(array)
      set_array(:without, array)
    end

    def with=(array)
      set_array(:with, array)
    end

    def without
      get_array(:without)
    end

    def with
      get_array(:with)
    end

    # @local_config["BUNDLE_PATH"] should be prioritized over ENV["BUNDLE_PATH"]
    def path
      key  = key_for(:path)
      path = ENV[key] || @global_config[key]
      return path if path && !@local_config.key?(key)

      if path = self[:path]
        "#{path}/#{Bundler.ruby_scope}"
      else
        Bundler.rubygems.gem_dir
      end
    end

    def allow_sudo?
      !@local_config.key?(key_for(:path))
    end

    def ignore_config?
      ENV["BUNDLE_IGNORE_CONFIG"]
    end

    def app_cache_path
      @app_cache_path ||= begin
        path = self[:cache_path] || "vendor/cache"
        raise InvalidOption, "Cache path must be relative to the bundle path" if path.start_with?("/")
        path
      end
    end

  private

    def key_for(key)
      key = Settings.normalize_uri(key).to_s if key.is_a?(String) && /https?:/ =~ key
      key = key.to_s.gsub(".", "__").upcase
      "BUNDLE_#{key}"
    end

    def parent_setting_for(name)
      split_specfic_setting_for(name)[0]
    end

    def specfic_gem_for(name)
      split_specfic_setting_for(name)[1]
    end

    def split_specfic_setting_for(name)
      name.split(".")
    end

    def is_bool(name)
      BOOL_KEYS.include?(name.to_s) || BOOL_KEYS.include?(parent_setting_for(name.to_s))
    end

    def to_bool(value)
      !(value.nil? || value == "" || value =~ /^(false|f|no|n|0)$/i || value == false)
    end

    def is_num(value)
      NUMBER_KEYS.include?(value.to_s)
    end

    def get_array(key)
      self[key] ? self[key].split(":").map(&:to_sym) : []
    end

    def set_array(key, array)
      self[key] = (array.empty? ? nil : array.join(":")) if array
    end

    def set_key(key, value, hash, file)
      key = key_for(key)

      unless hash[key] == value
        hash[key] = value
        hash.delete(key) if value.nil?
        SharedHelpers.filesystem_access(file) do |p|
          FileUtils.mkdir_p(p.dirname)
          p.open("w") {|f| f.write(serialize_hash(hash)) }
        end
      end

      value
    end

    def serialize_hash(hash)
      yaml = String.new("---\n")
      hash.each do |key, value|
        yaml << key << ": " << value.to_s.gsub(/\s+/, " ").inspect << "\n"
      end
      yaml
    end

    def global_config_file
      if ENV["BUNDLE_CONFIG"] && !ENV["BUNDLE_CONFIG"].empty?
        Pathname.new(ENV["BUNDLE_CONFIG"])
      else
        Bundler.user_bundle_path.join("config")
      end
    end

    def local_config_file
      Pathname.new(@root).join("config") if @root
    end

    CONFIG_REGEX = %r{ # rubocop:disable Style/RegexpLiteral
      ^
      (BUNDLE_.+):\s # the key
      (?: !\s)? # optional exclamation mark found with ruby 1.9.3
      (['"]?) # optional opening quote
      (.* # contents of the value
        (?: # optionally, up until the next key
          (\n(?!BUNDLE).+)*
        )
      )
      \2 # matching closing quote
      $
    }xo

    def load_config(config_file)
      SharedHelpers.filesystem_access(config_file, :read) do
        valid_file = config_file && config_file.exist? && !config_file.size.zero?
        return {} if ignore_config? || !valid_file
        config_pairs = config_file.read.scan(CONFIG_REGEX).map do |m|
          key, _, value = m
          [convert_to_backward_compatible_key(key), value.gsub(/\s+/, " ").tr('"', "'")]
        end
        Hash[config_pairs]
      end
    end

    def convert_to_backward_compatible_key(key)
      key = "#{key}/" if key =~ /https?:/i && key !~ %r{/\Z}
      key = key.gsub(".", "__") if key.include?(".")
      key
    end

    # TODO: duplicates Rubygems#normalize_uri
    # TODO: is this the correct place to validate mirror URIs?
    def self.normalize_uri(uri)
      uri = uri.to_s
      uri = "#{uri}/" unless uri =~ %r{/\Z}
      uri = URI(uri)
      unless uri.absolute?
        raise ArgumentError, "Gem sources must be absolute. You provided '#{uri}'."
      end
      uri
    end
  end
end
