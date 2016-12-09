require 'httparty'
require 'nokogiri'

class DtuBase
  attr_reader :reason, :email, :firstname, :lastname, :initials,
    :matrikel_id, :user_type, :library_access, :org_units, :studentcode, :address, :account, :cpr

  def self.lookup(attrs)
    dtubase = self.new
    dtubase.lookup_single(attrs)
    [ dtubase.to_hash, dtubase.address ]
  end

  def self.lookup_xml(attrs)
    dtubase = self.new
    dtubase.lookup_single(attrs)
    dtubase.account.to_xml
  end

  def self.cwis_for_studentcode(studentcode)
    profile = lookup_student_profile(studentcode)
    profile = profile && profile['root'] && profile['root']['profile_student']
    profile = profile.first if profile.is_a? Array
    profile['fk_matrikel_id'] if profile
  end

  def self.lookup_student_profile(attrs)
    response = self.new.generic_request('/account/profile_student', attrs)
  end

  def lookup_single(attrs)
    identifier = attrs[:cwis] || attrs[:username]
    attr = attrs[:cwis] ? "matrikel_id" : "username"
    response = request('account', attr, identifier)
    unless response.success?
      return
    end

    # Intercept DTUBasen errors that still return an HTTP 200
    md = /^<\?xml .*?>\s*<Error>(.*)<\/Error>$/m.match(response.body)
    raise "DTUBasen error: #{md[1]}" if md

    entry = Nokogiri.XML(response.body, nil, 'UTF-8')
    @account = entry.xpath('//account')
    parse_account(@account)
  end

  def parse_account(account)
    # Get the basic information even if we fail later
    @firstname = account.xpath('@firstname').text
    @lastname = account.xpath('@lastname').text
    @email = account.xpath('@official_email_address').text
    @initials = account.xpath('@dtu_initials').text
    @matrikel_id = account.xpath('@matrikel_id').text
    @library_access = account.xpath('@external_Biblioteket').text
    @cpr = account.xpath('@cprnr').text.gsub('-', '')
    @reason = nil
    @org_units = Array.new
    logger.info "Matrikel id #{matrikel_id}"

    if has_active_employee_or_student_profile(account)
      @library_access = '1'
    end

    profile = dtu_select_profile(account)
    if profile.nil?
      @reason ||= 'dtu_no_primary_profile'
      logger.warn "Doing fallback because of missing (active) primary "\
        "profile for #{@matrikel_id}"
      profile = dtu_select_active_profile(account)
      return nil if profile.nil?
    end
    logger.info "User type #{@user_type}"


    # Get organization unit
    org_unit_id = profile.xpath('@fk_orgunit_id').text
    org_unit = get_org_unit(org_unit_id)


    # Org unit must be in the correct groping
    unless valid_dtu_org_unit(org_unit)
      @reason ||= 'not_dtu_org'
      @user_type = 'private'
    end

    # Find organizations unit attached to this user
    # stud is skipped if phd is true.
    list = account.xpath("//*[@active = '1']")
    list.each do |node|
      if "#{node.attribute("phd")}" != '1' || list.count == 1
        id = node.xpath("@fk_orgunit_id").text
        @org_units << id unless @org_units.include?(id)
      end
    end


    # Find s-number for student profile
    if @user_type == 'student' && !profile.xpath('@stads_studentcode').blank?
      @studentcode = profile.xpath('@stads_studentcode').text
    end

    case @user_type
    when 'dtu_empl'
      create_employee_address org_unit, profile
    else
      create_student_or_guest_address org_unit, profile
    end

    logger.info "Lookup complete"
  end

  def create_employee_address(org_unit, profile)
    # Create organization address.
    adr = org_unit.xpath("address_dk[@is_primary_address = '1']") or
      org_unit.xpath("address_uk[@is_primary_address = '1']")
    org_address = extract_address (adr)
    org_address['name'] = org_unit.xpath('@name_dk').text or
      org_unit.xpath('@name_uk').text

    # Find the primary address
    adr = profile.xpath("address[@is_primary_address = '1']")
    adr = profile.xpath("address[position() = 1]") if adr.nil? || adr.empty?

    #
    user_address = extract_address (adr)

    # TODO: Make sure all fields are filled
    %w(street zipcode city country).each do |f|
      user_address[f] ||= org_address[f]
    end

    # Create address entry
    user_address['name'] = org_address['name']
    @address = create_address(user_address)
  end

  def create_student_or_guest_address(org_unit, profile)
    adr = profile.xpath("address[@is_primary_address = '1']")
    adr = profile.xpath("address[position() = 1]") if adr.nil? || adr.empty?
    user_address = extract_address (adr)
    @address = create_address(user_address)
  end

#  def success
#    @reason.nil?
#  end

  def to_hash
    values = Hash.new
    %w(reason email library_access firstname lastname initials matrikel_id
       user_type org_units studentcode).each do |k|
      values[k] = send(k)
    end
    values
  end

  def self.config
    Rails.application.config.dtubase
  end

  def cpr
    @cpr
  end

  def generic_request(path, attrs)
    conditions = attrs.map{|attr, value| "@#{attr}='#{value}'"}.join(' and ')
    url = "#{config[:url]}?" +
      URI.encode_www_form(
      :XPathExpression => "#{path}[#{conditions}]",
      :username => config[:username],
      :password => config[:password],
      :dbversion => 'dtubasen'
      )
    response = HTTParty.get(url)
    unless response.success?
      @reason = 'lookup_failed'
      logger.warn "Could not get #{path} with #{conditions} from DTUbasen with request #{url}. Message: #{response.message}."
    end
    response

  end

  def request_removed_accounts
    url = "#{config[:url]}?" +
      URI.encode_www_form(
        :XPathExpression => "/removed_account",
        :username => config[:username],
        :password => config[:password],
        :dbversion => 'dtubasen'
      )
    response = HTTParty.get(url)
    unless response.success?
      @reason = 'lookup_failed'
      logger.warn "Could not get /removed_account from DTUbasen with request #{url}. Message: #{response.message}."
    end
    (((response || {})["root"] || {})["removed_account"] || []).sort_by { |removed_account| (removed_account["date_removed"] || "") }
  end

  private

  def has_active_employee_or_student_profile(account)
    employee_profiles = account.xpath("profile_employee[@active = '1']")
    student_profiles  = account.xpath("profile_student[@active = '1']")
    !(employee_profiles.empty? && student_profiles.empty?)
  end

  def has_active_employee_profile(account)
    employee_profiles = account.xpath("profile_employee[@active = '1']")
    !employee_profiles.empty?
  end

  def is_phd_student_profile(profile)
    !profile.xpath("@phd='1'").empty?
  end

  def dtu_select_profile(account)
    @user_type = nil
    primary_id = account.xpath("@primary_profile_id").text
    logger.info "Primary id #{primary_id}"
    profile = account.xpath(
      "profile_employee[@fk_profile_id = #{primary_id} and @active = '1']")
    if !profile.empty?
      @user_type = "dtu_empl"
    else
      profile = account.xpath(
        "profile_student[@fk_profile_id = #{primary_id} and @active = '1']")
      if !profile.empty?
        @user_type = 'student'
        phd = profile.xpath('@phd').text
        if phd == '1'
          @reason ||= "dtu_catch_student_active"
          employee_profile = account.xpath("profile_employee[@active = '1']")
          if !employee_profile.empty?
            @reason = "dtu_phd_catch_student_primary"
            profile = employee_profile
            @user_type = 'dtu_empl'
          end
        end
      else
        profile = account.xpath(
          "profile_guest[@fk_profile_id = #{primary_id} and @active = '1']")
        if @library_access == "1"
          @user_type = "dtu_empl"
        else
          @user_type = "private"
        end
      end
    end

    return nil if profile.empty?
    profile.first
  end

  def dtu_select_active_profile(account)
    profile = account.xpath("profile_student[@active = '1']")
    if !profile.empty?
      phd = profile.xpath('@phd').text
      logger.info "PHD: #{phd} #{phd == '0'}"
      if phd == '0'
        @user_type = 'student'
        return profile.first
      end
    end

    profile = account.xpath("profile_employee[@active = '1']")
    if !profile.empty?
      @user_type = 'dtu_empl'
      return profile.first
    end

    profile = account.xpath("profile_guest[@active = '1']")
    if !profile.empty?
      @user_type = 'dtu_empl'
      return profile.first
    end

    # This catches a case when student is marked phd, but no employee
    # entry have been created.
    profile = account.xpath("profile_student[@active = '1']")
    if !profile.empty?
      @reason ||= "dtu_catch_student_active"
      @user_type = 'student'
      return profile.first
    end
    return nil
  end

  def get_org_unit (id)
    response = request('orgunit', 'orgunit_id', id)
    return nil if response.nil?

    entry = Nokogiri.XML(response.body, nil, 'UTF-8')
    entry.xpath('//orgunit')
  end

  def request(type, attr, identifier)
    url = "#{config[:url]}?" +
      URI.encode_www_form(
        :XPathExpression => "/#{type}[@#{attr}=\'%s\']" % identifier,
        :username => config[:username],
        :password => config[:password],
        :dbversion => 'dtubasen'
      )
    response = HTTParty.get(url)
    unless response.success?
      @reason = 'lookup_failed'
      logger.warn "Could not get #{type} with #{attr} containing "\
        "#{identifier} from DTUbasen with request #{url}. Message: "\
        "#{response.message}."
    end
    response
  end

  # Return hash with values for address
  def extract_address (address)
    hash = Hash.new
    hash['street']   = address.xpath('@street').text
    hash['building'] = address.xpath('@building').text
    hash['room']     = address.xpath('@room').text
    hash['zipcode']  = address.xpath('@zipcode').text
    hash['city']     = address.xpath('@city').text
    hash['country']  = address.xpath('@country').text.upcase
    return hash
  end

  def create_address(fields)
    address = Address.new
    if fields['name']
      address << fields['name']
      address << "Att: #{@firstname} #{@lastname}"
    else
      address << "#{@firstname} #{@lastname}"
    end
    if !fields['building'].blank? or !fields['room'].blank?
      line = ''
      sep = ''
      if fields['building'] != ''
        line += "Bygning "+fields['building']
        sep = ', '
      end
      if fields['room'] != ''
        line += sep + "Rum "+fields['room']
      end
      address << line
    end
    fields['street'].split(/\r?\n/).each { |line| address << line }
    address.zipcode = fields['zipcode']
    address.cityname = fields['city']
    address.country = fields['country']
    address
  end

  def valid_dtu_org_units
    [
      'stud', # Students
    ]
  end

  def valid_dtu_org_unit(org_unit)
    return true if valid_dtu_org_units.include? org_unit.xpath('@orgunit_id').text

    # Valid if parent is instgrp or admgrp
    flag = org_unit.xpath('@fk_parentunit_id').text
    while flag != ''
      return true if flag == 'instgrp' || flag == 'admgrp'
      org_unit = get_org_unit(flag)
      flag = org_unit.xpath('@fk_parentunit_id').text
    end
    return false
  end

  def logger
    Rails.logger
  end

  def config
    Rails.application.config.dtubase
  end

end
