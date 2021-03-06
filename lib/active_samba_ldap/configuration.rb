require 'socket'

module ActiveSambaLdap
  module Configuration
    def self.included(base)
      base.extend(ClassMethods)
    end

    class << self
      def read(file)
        require 'yaml'
        require 'erb'
        erb = ERB.new(File.read(file))
        erb.filename = file
        result = nil
        begin
          begin
            result = YAML.load(erb.result)
            unless result
              raise InvalidConfigurationFormatError.new(file, "0",
                                                        "empty source")
            end
          rescue ArgumentError
            if /syntax error on line (\d+), col (\d+): `(.*)'/ =~ $!.message
              raise InvalidConfigurationFormatError.new(file, "#{$1}:#{$2}", $3)
            else
              raise
            end
          end
        rescue InvalidConfigurationFormatError
          raise
        rescue Exception
          file, location = $@.first.split(/:/, 2)
          detail = "#{$!.class}: #{$!.message}"
          raise InvalidConfigurationFormatError.new(file, location, detail)
        end
        result
      end
    end

    module ClassMethods
      class ValidHash < Hash
        def [](name)
          if Private.required_variables.include?(name) and !has_key?(name)
            raise MissingRequiredVariableError.new(name)
          end
          super(name)
        end
      end

      def remove_connection_related_configuration(config)
        target_keys = Private::VARIABLES.collect do |name|
          name.to_sym
        end - ActiveLdap::Adapter::Base::VALID_ADAPTER_CONFIGURATION_KEYS
        super(config).reject do |key, value|
          target_keys.include?(key)
        end
      end

      def merge_configuration(config, *rest)
        config = config.symbolize_keys
        config = (configurations["common"] || {}).symbolize_keys.merge(config)
        ValidHash.new.merge(super(Private.new(config).merge, *rest))
      end

      def required_configuration_variables(*names)
        config = configuration
        if config.nil?
          missing_variables = names
        else
          missing_variables = names.find_all do |name|
            config[name.to_sym].nil?
          end
        end
        unless missing_variables.empty?
          raise MissingRequiredVariableError.new(missing_variables)
        end
      end

      class Private
        include ActiveSambaLdap::GetTextSupport

        VARIABLES = %w(base host port scope bind_dn
                       password method allow_anonymous

                       sid smb_conf samba_domain samba_netbios_name
                       password_hash_type

                       users_suffix groups_suffix computers_suffix
                       idmap_suffix

                       start_uid start_gid

                       user_login_shell user_home_directory
                       user_home_directory_mode
                       user_gecos user_home_unc user_profile
                       user_home_drive user_logon_script mail_domain

                       skeleton_directory

                       default_user_gid default_computer_gid
                       default_max_password_age

                       samba4)

        class << self
          def required_variables
            @required_variables ||= compute_required_variables
          end

          def compute_required_variables
            not_required_variables = %w(base scope ldap_scope)
            (VARIABLES - public_methods - not_required_variables).collect do |x|
              x.to_sym
            end
          end
        end

        def initialize(target)
          @target = target.symbolize_keys
        end

        def merge
          result = @target.dup
          VARIABLES.each do |variable|
            key = variable.to_sym
            result[key] ||= send(variable) if respond_to?(variable)

            normalize_method = "normalize_#{variable}"
            if respond_to?(normalize_method)
              result[key] = __send__(normalize_method, result[key])
            end

            validate_method = "validate_#{variable}"
            if respond_to?(validate_method)
              __send__(validate_method, result[key])
            end
          end
          result
        end

        def [](name)
          @target[name.to_sym] || (respond_to?(name) ? send(name) : nil)
        end

        def sid
          result = `net getlocalsid`
          if $?.success?
            result.chomp.gsub(/\G[^:]+:\s*/, '')
          else
            nil
          end
        end

        def smb_conf
          %w(/etc/samba/smb.conf /usr/local/etc/samba/smb.conf).each do |guess|
            return guess if File.exist?(guess)
          end
          nil
        end

        def samba_domain
          _smb_conf = self["smb_conf"]
          if _smb_conf
            File.open(_smb_conf) do |f|
              f.read.grep(/^\s*[^#;]/).each do |line|
                if /^\s*workgroup\s*=\s*(\S+)\s*$/i =~ line
                  return $1.upcase
                end
              end
            end
          else
            nil
          end
        end

        def samba_netbios_name
          netbios_name = nil
          _smb_conf = self["smb_conf"]
          if _smb_conf
            File.open(_smb_conf) do |f|
              f.read.grep(/^\s*[^#;]/).each do |line|
                if /^\s*netbios\s*name\s*=\s*(.+)\s*$/i =~ line
                  netbios_name = $1
                  break
                end
              end
            end
          end
          netbios_name ||= Socket.gethostname
          netbios_name ? netbios_name.upcase : nil
        end

        def host
          "localhost"
        end

        def port
          389
        end

        def allow_anonymous
          false
        end

        def method
          :plain
        end

        def users_suffix
          suffix = retrieve_value_from_smb_conf(/ldap\s+user\s+suffix/i)
          return suffix if suffix
          if self[:samba4]
            "cn=Users"
          else
            "ou=Users"
          end
        end

        def groups_suffix
          suffix = retrieve_value_from_smb_conf(/ldap\s+group\s+suffix/i)
          return suffix if suffix
          if self[:samba4]
            "cn=Users"
          else
            "ou=Groups"
          end
        end

        def computers_suffix
          suffix = retrieve_value_from_smb_conf(/ldap\s+machine\s+suffix/i)
          return suffix if suffix
          if self[:samba4]
            "cn=Computers"
          else
            "ou=Computers"
          end
        end

        def idmap_suffix
          retrieve_value_from_smb_conf(/ldap\s+idmap\s+suffix/i) || "ou=Idmap"
        end

        def start_uid
          10000
        end

        def start_gid
          10000
        end

        def default_user_gid
          rid = ActiveSambaLdap::Group::DOMAIN_USERS_RID
          ActiveSambaLdap::Group.rid2gid(rid)
        end

        def default_computer_gid
          rid = ActiveSambaLdap::Group::DOMAIN_COMPUTERS_RID
          ActiveSambaLdap::Group.rid2gid(rid)
        end

        def skeleton_directory
          "/etc/skel"
        end

        def user_home_unc
          netbios_name = self["samba_netbios_name"]
          netbios_name ? "\\\\#{netbios_name}\\%U" : nil
        end

        def user_profile
          netbios_name = self["samba_netbios_name"]
          netbios_name ? "\\\\#{netbios_name}\\profiles\\%U" : nil
        end

        def user_home_directory
          "/home/%U"
        end

        def user_home_directory_mode
          0755
        end

        def normalize_user_home_directory_mode(mode)
          if mode
            Integer(mode)
          else
            nil
          end
        rescue ArgumentError
          raise InvalidConfigurationValueError.new("user_home_directory",
                                                   mode, $!.message)
        end

        def user_login_shell
          "/bin/false"
        end

        def user_home_drive
          "H:"
        end

        def user_logon_script
          "logon.bat"
        end

        def user_gecos
          nil
        end

        def bind_dn
          nil
        end

        def password_hash_type
          :ssha
        end

        def normalize_password_hash_type(type)
          type.to_s.downcase.to_sym
        end

        def samba4
          smb_conf = self[:smb_conf]
          if smb_conf and /^\s*server\s*role\s*=/ =~ File.read(smb_conf)
            true
          else
            false
          end
        end

        AVAILABLE_HASH_TYPES = [:crypt, :md5, :smd5, :sha, :ssha]
        def validate_password_hash_type(type)
          unless AVAILABLE_HASH_TYPES.include?(type)
            types = AVAILABLE_HASH_TYPES.collect {|x| x.inspect}.join(", ")
            raise InvalidConfigurationValueError.new("password_hash_type",
                                                     type,
                                                     _("must be in %s") % types)
          end
        end

        private
        def retrieve_value_from_smb_conf(key)
          smb_conf = self['smb_conf']
          if smb_conf and File.readable?(smb_conf)
            line = File.read(smb_conf).grep(key).reject do |l|
              /^\s*[#;]/ =~ l
            end.first
            if line
              line.split(/=/, 2)[1].strip
            else
              nil
            end
          else
            nil
          end
        end
      end
    end
  end
end
