require 'English'

module ActiveSambaLdap
  class Group < Base
    # from source/include/rpc_misc.c in Samba
    DOMAIN_ADMINS_RID = 0x00000200
    DOMAIN_USERS_RID = 0x00000201
    DOMAIN_GUESTS_RID = 0x00000202
    DOMAIN_COMPUTERS_RID = 0x00000203

    LOCAL_ADMINS_RID = 0x00000220
    LOCAL_USERS_RID = 0x00000221
    LOCAL_GUESTS_RID = 0x00000222
    LOCAL_POWER_USERS_RID = 0x00000223

    LOCAL_ACCOUNT_OPERATORS_RID = 0x00000224
    LOCAL_SYSTEM_OPERATORS_RID = 0x00000225
    LOCAL_PRINT_OPERATORS_RID = 0x00000226
    LOCAL_BACKUP_OPERATORS_RID = 0x00000227

    LOCAL_REPLICATORS_RID = 0x00000228


    # from source/rpc_server/srv_util.c in Samba
    DOMAIN_ADMINS_NAME = "Domain Administrators"
    DOMAIN_USERS_NAME = "Domain Users"
    DOMAIN_GUESTS_NAME = "Domain Guests"
    DOMAIN_COMPUTERS_NAME = "Domain Computers"


    WELL_KNOWN_RIDS = []
    WELL_KNOWN_NAMES = []
    constants.each do |name|
      case name
      when /_RID$/
        WELL_KNOWN_RIDS << const_get(name)
      when /_NAME$/
        WELL_KNOWN_NAMES << const_get(name)
      end
    end


    # from source/librpc/idl/lsa.idl in Samba
    TYPES = {
      "domain" => 2,
      "local" => 4,
      "builtin" => 5,
    }

    class << self
      def ldap_mapping(options={})
        Config.required_variables :groups_prefix
        default_options = {
          :dnattr => "cn",
          :prefix => Config.groups_prefix,
          :classes => ["posixGroup", "sambaGroupMapping"],

          :member_local_key => "memberUid",
          :user_member_class_name => "User",
          :computer_member_class_name => "Computer",

          :primary_member_foreign_key => "gidNumber",
          :primary_member_local_key => "gidNumber",
          :primary_user_member_class_name => "User",
          :primary_computer_member_class_name => "Computer",
        }
        options = default_options.merge(options)
        super options
        init_associations(options)
      end

      def create(name, options={})
        group = new(name)
        gid_number, pool = ensure_gid_number(options)
        group.change_gid_number(gid_number)
        group.change_type(options[:group_type] || "domain")
        group.description = options[:description] || name
        group.displayName = options[:display_name] || name
        if group.save and pool
          pool.gidNumber = Integer(group.gidNumber(true)).succ
          pool.save!
        end
        group
      end

      def destroy(name, options={})
        new(name).destroy(options)
      end

      def find_by_name_or_gid_number(key)
        group = nil
        begin
          gid_number = Integer(key)
          group = find_by_gid_number(gid_number)
          raise GidNumberDoesNotExist.new(gid_number) if group.nil?
        rescue ArgumentError
          group = new(key)
          raise GroupDoesNotExist.new(key) unless group.exists?
        end
        group
      end

      def find_by_gid_number(number)
        options = {:objects => true}
        attribute = "gidNumber"
        value = Integer(number).to_s
        if Base::OLD_ACTIVE_LDAP
          options[:attribute] = attribute
          options[:value] = value
        else
          options[:filter] = "(#{attribute}=#{value})"
        end
        find(options)
      end

      def gid2rid(gid)
        gid = Integer(gid)
        if WELL_KNOWN_RIDS.include?(gid)
          gid
        else
          2 * gid + 1001
        end
      end

      def rid2gid(rid)
        rid = Integer(rid)
        if WELL_KNOWN_RIDS.include?(rid)
          rid
        else
          (rid - 1001) / 2
        end
      end

      def start_gid
        ActiveSambaLdap::Config.required_variables :start_gid
        Integer(ActiveSambaLdap::Config.start_gid)
      end

      def start_rid
        gid2rid(start_gid)
      end

      def find_available_gid_number(pool)
        gid_number = pool.gidNumber(true) || start_gid

        100.times do |i|
          if find(:attribute => "gidNumber", :value => gid_number).nil?
            return gid_number
          end
          gid_number = gid_number.succ
        end

        nil
      end

      private
      def init_associations(options)
        association_options = {}
        options.each do |key, value|
          case key.to_s
          when /^((?:primary_)?(?:(?:user|computer)_)?member)_/
            association_options[$1] ||= {}
            association_options[$1][$POSTMATCH.to_sym] = value
          end
        end

        member_opts = association_options["member"] || {}
        user_member_opts = association_options["user_member"] || {}
        computer_member_opts = association_options["computer_member"] || {}
        has_many :user_members, member_opts.merge(user_member_opts)
        has_many :computer_members,
                 member_opts.merge(computer_member_opts)

        primary_member_opts = association_options["primary_member"] || {}
        primary_user_member_opts =
          association_options["primary_user_member"] || {}
        primary_computer_member_opts =
          association_options["primary_computer_member"] || {}
        belongs_to :primary_user_members,
                    primary_member_opts.merge(primary_user_member_opts)
        belongs_to :primary_computer_members,
                    primary_member_opts.merge(primary_computer_member_opts)
      end

      def ensure_gid_number(options)
        gid_number = options[:gid_number]
        pool = nil
        unless gid_number
          pool_class = options[:pool_class] || Class.new(UnixIdPool)
          pool = pool_class.new(options[:samba_domain] || Config[:samba_domain])
          gid_number = find_available_gid_number(pool)
        end
        [gid_number, pool]
      end
    end

    def members(*args)
      user_members(*args) + computer_members(*args)
    end

    def primary_members(*args)
      primary_user_members(*args) + primary_computer_members(*args)
    end

    def change_gid_number(gid, allow_non_unique=false)
      check_unique_gid_number(gid) unless allow_non_unique
      rid = self.class.gid2rid(gid)
      self.gidNumber = gid.to_s
      change_sid(rid, allow_non_unique)
    end

    def change_gid_number_by_rid(rid, allow_non_unique=false)
      change_uid_number(self.class.rid2gid(rid), allow_non_unique)
    end

    def change_sid(rid, allow_non_unique=false)
      sid = "#{ActiveSambaLdap::Config.sid}-#{rid}"
      # check_unique_sid_number(sid) unless allow_non_unique
      self.sambaSID = sid
    end

    def rid
      Integer(sambaSID(true).split(/-/).last)
    end

    def change_type(type)
      normalized_type = type.to_s.downcase
      if TYPES.has_key?(normalized_type)
        type = TYPES[normalized_type]
      elsif TYPES.values.include?(type.to_i)
	# pass
      else
        raise ArgumentError, "invalid type: #{type}"
      end
      self.sambaGroupType = type.to_s
    end

    def remove_member(member_or_uid)
      uid = ensure_uid(member_or_uid)
      new_memberUid = memberUid.dup
      unless new_memberUid.reject! {|_uid| uid == _uid}.nil?
        self.memberUid = new_memberUid
        save!
      end
    end

    def add_member(member_or_uid)
      uid = ensure_uid(member_or_uid)
      unless memberUid.find {|_uid| uid == _uid}
        self.memberUid = (memberUid + [uid]).sort
        save!
      end
    end

    def destroy(options={})
      if options[:remove_members]
        if options[:force_change_primary_members]
          change_primary_members(options)
        end
        pr_members = primary_members
        unless pr_members.empty?
          raise PrimaryGroupCanNotBeDestroyed.new(cn(true), pr_members)
        end
        members(true).each do |member|
          remove_member(member)
        end
      end
      super()
    end

    private
    def ensure_uid(member_or_uid)
      if member_or_uid.is_a?(String)
        member_or_uid
      else
        member_or_uid.uid(true)
      end
    end

    def check_unique_gid_number(gid_number)
      ActiveSambaLdap::Base.restart_nscd do
        if self.class.find_by_gid_number(Integer(gid_number))
          raise GidNumberAlreadyExists.new(gid_number)
        end
      end
    end

    def change_primary_members(options={})
      name = cn(true)

      pr_members = primary_members(true)
      cannot_removed_members = []
      pr_members.each do |member|
        if (member.groups - [name]).empty?
          cannot_removed_members << member.uid(true)
        end
      end
      unless cannot_removed_members.empty?
        raise CanNotChangePrimaryGroup.new(name, cannot_removed_members)
      end

      pr_members.each do |member|
        new_group = member.groups(true).find {|gr| gr.cn != name}
        member.change_group(new_group.gidNumber(true))
        member.save!
      end
    end
  end
end
