module PermClerk
  require 'date'
  require 'pry'
  require 'logger'

  @logger = Logger.new("perm_clerk.log")
  @logger.level = Logger::INFO

  @runStatus = eval(File.open("lastrun", "r")) rescue {}
  @runFile = File.open("lastrun", "w")

  COMMENT_INDENT = "\n::"
  COMMENT_PREFIX = "{{comment|Automated comment}} "
  EDIT_THROTTLE = 3
  SPLIT_KEY = "====[[User:"
  # PERMISSIONS = [
  #   "Account creator",
  #   "Autopatrolled",
  #   "Confirmed",
  #   "File mover",
  #   "Pending changes reviewer",
  #   "Rollback",
  #   "Template editor"
  # ]
  PERMISSIONS = ["Rollback"]
  PERMISSION_KEYS = {
    "Account creator" => "accountcreator",
    "Autopatrolled" => "autopatrolled",
    "Confirmed" => "(?=>auto)?confirmed",
    "File mover" => "filemover",
    "Pending changes reviewer" => "reviewer",
    "Rollback" => "rollbacker",
    "Template editor" => "templateeditor"
  }

  @userLinksCache = {}
  @userInfoCache = {}
  @deniedCache = {}

  def self.init(mw, config)
    @mw = mw
    @config = config

    for @permission in PERMISSIONS
      @baseTimestamp = nil
      @editThrottle = 0
      @headersRemoved = {}
      @pageName = "Wikipedia:Requests for permissions/#{@permission}"
      @usersCount = 0
      unless process(@permission)
        error("Failed to process")
      else
        info("Processing of #{@permission} complete")
        @runStatus[@permission] = DateTime.now.new_offset(0)
      end
      @logger.info("\n#{'=' * 100}")
      sleep 2
    end
    @logger.info("Task complete\n#{'~' * 100}")

    @runFile.write(@runStatus.inspect)
    @runFile.close
  end

  def self.process(permission)
    info("Processing #{permission}...")
    newWikitext = []
    @fetchThrotte = 0

    oldWikitext = setPageProps
    return false unless oldWikitext

    if DateTime.parse(@baseTimestamp).new_offset(0) + Rational(1, 24) < DateTime.now.new_offset(0)
      info("  Page has not been modified in over an hour")
      return true
    end

    if @config["autoformat"]
      debug("Checking for extraneous headers")
      oldWikitext = removeHeaders(oldWikitext)
    end

    sections = oldWikitext.split(SPLIT_KEY)
    newWikitext << sections.shift

    sections.each do |section|

      requestChanges = []

      if userNameMatch = section.match(/{{(?:template\:)?rfplinks\|1=(.*)}}/i)
        userName = userNameMatch.captures[0].gsub("_", " ")

        info("Checking section for User:#{userName}...")

        archiveRequested = section.include?("{{User:MusikBot.*Archive\s*now}}")
        timestamps = section.scan(/\d\d:\d\d.*\d{4} \(UTC\)/)
        newestTimestamp = timestamps.min {|a,b| DateTime.parse(b).new_offset(0) <=> DateTime.parse(a).new_offset(0)}
        resolution = section.match(/#{@config["archive_done"]}/i) ? "done" : section.match(/#{@config["archive_notdone"]}/i) ? "notdone" : false

        if resolution || section.match(/::{{comment|Automated comment}}.*MusikBot/)
          info("  #{userName}'s request already responded to or MusikBot has already commented")
        elsif timestamps[0] && DateTime.parse(timestamps[0]).new_offset(0) + Rational(30, 1440) < DateTime.now.new_offset(0)
          info("  #{userName}'s request is over 30 minutes old")

          # ARCHIVING
          if @config["archive"]
            if DateTime.parse(newestTimestamp).new_offset(0) < DateTime.now.new_offset(0) - Rational(@config["archive_offset"].to_i, 24) && @runStatus[]
              info("  Request eligible for archiving")
              userInfo = getUserInfo(userName)

              if section.match(/#{@config["archive_done"]}|#{@config["archive_notdone"]}/i)
                !userInfo[:userGroups].include?(PERMISSION_KEYS[@permission])
                info("  User group does not match request response")
              else
                # archive request
                puts "archive #{userName}"
              end
            end
          end
        else
          haveResponded = false

          # AUTORESPOND
          if @config["autorespond"] &&
            debug("  Checking if #{userName} already has permission #{@permission}...")

            if userInfo = getUserInfo(userName)
              if userInfo[:userGroups].include?(PERMISSION_KEYS[@permission])
                info("    Found matching user group")
                requestChanges << {
                  type: :autorespond,
                  permission: @permission.downcase,
                  resolution: "{{already done}}"
                }
                haveResponded = true
              end
            end
          end

          # AUTOFORMAT
          if @config["autoformat"]
            debug("  Checking if request is fragmented...")

            fragmentedRegex = /{{rfplinks.*}}\n:(Reason for requesting (?:#{PERMISSIONS.join("|").downcase}) rights) .*\(UTC\)\n*(.*)/
            fragmentedMatch = section.scan(fragmentedRegex)

            if fragmentedMatch.length > 0
              info("    Found improperly formatted request for #{userName}, repairing")

              actualReason = fragmentedMatch.flatten[1]

              if actualReason.length == 0 && @headersRemoved[userName]
                actualReason = @headersRemoved[userName]
              else
                section.gsub!(actualReason, "")
                loop do
                  fragMatch = section.match(fragmentedRegex)
                  if fragMatch && fragMatch[2] != "" && !(fragMatch[2].include?("UTC") && !fragMatch[2].include?(userName))
                    reasonPart = fragMatch[2]
                    actualReason += "\n:#{reasonPart}"
                    section.gsub!(reasonPart, "")
                  else
                    break
                  end
                end
              end

              section.gsub!(fragmentedMatch.flatten[0], actualReason)

              duplicateSig = section.scan(/.*\(UTC\)(.*\(UTC\))/)
              if duplicateSig.length > 0
                info("    Duplicate signature found, repairing")
                sig = duplicateSig.flatten[0]
                section = section.sub(sig, "")
              end

              requestChanges << { type: :autoformat }
            elsif @headersRemoved[userName] && @headersRemoved[userName].length > 0
              requestChanges << { type: :autoformat }
            end
          end

          if !haveResponded && @permission != "Confirmed"
            # CHECK PREREQUISTES
            if @config["prerequisites"]
              debug("  Checking if #{userName} meets configured prerequisites...")

              sleep 1
              userInfo = getUserInfo(userName)

              prereqs = @config["prerequisites_config"][@permission.downcase.gsub(/ /,"_")]

              prereqs.each do |key, value|
                pass = case key
                  when "accountAge"
                    Date.today - value.to_i >= Date.parse(userInfo[:accountAge])
                  when "articleCount"
                    userInfo[:articleCount].to_i >= value
                  when "editCount"
                    userInfo[:editCount].to_i >= value
                  when "mainspaceCount"
                    userInfo[:mainspaceCount].to_i >= value
                end

                unless pass
                  info("    Found unmet prerequisites")
                  requestChanges << { type: key }.merge(userInfo)
                end
              end
            end

            # FETCH DECLINED
            if @config["fetchdeclined"]
              debug("  Searching for declined #{@permission} requests by #{userName}...")

              begin
                links = findLinks(userName)

                if links.length > 0
                  info("    Found previously declined requests")
                  linksMessage = links.map{|l| "[#{l}]"}.join

                  requestChanges << {
                    type: :fetchdeclined,
                    numDeclined: links.length,
                    declinedLinks: linksMessage
                  }
                end
              rescue => e
                warn("    Unknown exception when finding links: #{e.message}")
              end
            end
          end
        end

        if requestChanges.length > 0
          info("***** Commentable data found for #{userName} *****")
          @usersCount += 1
          newWikitext << SPLIT_KEY + section.gsub(/\n+$/,"") + messageCompiler(requestChanges)
        else
          info("  No commentable data found for #{userName}")
          newWikitext << SPLIT_KEY + section
        end
      else
        newWikitext << SPLIT_KEY + section
      end
    end

    return editPage(CGI.unescapeHTML(newWikitext.join))
  end

  def self.editPage(newWikitext)
    unless @usersCount > 0 || headersRemoved?
      info("No commentable data found for any of the current requests")
      return true
    end

    if @editThrottle < 3
      sleep @editThrottle
      @editThrottle += 1

      info("Attempting to write to page [[#{@pageName}]]")

      # FIXME: cover all bases here, or write "commented on X requests, repaired malformed requests"
      fixes = []
      fixes << "commented on #{@usersCount} request#{'s' if @usersCount > 1}" if @usersCount > 0
      fixes << "repaired #{@headersRemoved.length} malformed request#{'s' if @headersRemoved.length > 1}" if headersRemoved?

      # attempt to save
      begin
        @mw.edit(@pageName, newWikitext, {
          basetimestamp: @baseTimestamp,
          contentformat: "text/x-wiki",
          starttimestamp: @startTimestamp,
          summary: "Bot clerking, #{fixes.join(', ')}",
          text: newWikitext
        })
      rescue MediaWiki::APIError => e
        if e.code.to_s == "editconflict"
          warn("Edit conflict, trying again")
          return process(@permission)
        else
          warn("API error when writing to page: #{e.code.to_s}, trying again")
          return process(@permission)
        end
      rescue => e
        error("Unknown exception when writing to page: #{e.message}") and return false
      end
    else
      error("Throttle hit for edit page operation, continuing to process next permission") and return false
    end

    true
  end

  def self.findLinks(userName)
    if @userLinksCache[userName]
      # debug("Cache hit for #{userName}")
      return @userLinksCache[userName]
    end

    currentDate = Date.today
    targetDate = currentDate - @config["fetchdeclined_offset"]
    links = []

    for date in (targetDate..currentDate)
      if dayWikitext = getDeniedForDate(date)
        if match = dayWikitext.scan(/{{Usercheck.*\|#{userName}}}.*\/#{@permission}\]\].*(http:\/\/.*)\s+link\]/i)[0]
          # TODO: fetch declining admin's username and ping them
          links << match.flatten[0]
        end
      end
    end

    return @userLinksCache[userName] = links
  end

  def self.getDeniedForDate(date)
    key = "#{Date::MONTHNAMES[date.month]} #{date.year}"
    if @deniedCache[key]
      # debug("Cache hit for #{key}")
      page = @deniedCache[key]
    else
      page = @mw.get("Wikipedia:Requests for permissions/Denied/#{key}")
      @deniedCache[key] = page
    end

    return nil unless page

    reduced = page.split(/==\s*\w+\s+/i)
    dayWikitext = reduced.select{|entry| entry.scan(/^(\d+)\s*==/).flatten[0].to_i == date.day.to_i}

    return dayWikitext[0]
  end

  def self.getUserInfo(userName)
    return @userInfoCache[userName] if @userInfoCache[userName]

    begin
      if @config["prerequisites"] && @config["prerequisites_config"].to_s.include?("editCount")
        query = @mw.custom_query(
          list: "users|usercontribs",
          ususers: userName,
          ucuser: userName,
          usprop: "groups|editcount|registration",
          ucprop: "ids",
          uclimit: 200,
          ucnamespace: "0"
        )
      else
        query = @mw.custom_query(
          list: "users",
          ususers: userName,
          usprop: "groups|editcount|registration"
        )
      end

      user = query[0][0].attributes

      userInfo = {
        editCount: user['editcount'],
        mainspaceCount: query[1] ? query[1].length : nil,
        registration: user['registration'],
        userGroups: query[0][0][0].to_a.collect{|g| g[0]}
      }

      return @userInfoCache[userName] = userInfo
    rescue => e
      error("Unable to fetch user info for #{userName}") and return false
    end
  end

  def self.headersRemoved?
    @headersRemoved.length > 0
  end

  def self.getMessage(type, params = {})
    return case type.to_sym
      when :autoformat
        "An extraneous header or other inappropriate text was removed from this request"
      when :autorespond
        "already has the \"#{params[:permission]}\" user right"
      when :editCount
        "has #{params[:editCount]} total edits"
      when :fetchdeclined
        "has had #{params[:numDeclined]} request#{'s' if params[:numDeclined].to_i > 1} for #{@permission.downcase} declined in the past #{@config["fetchdeclined_offset"]} days (#{params[:declinedLinks]})"
      when :mainspaceCount
        "has #{params[:mainspaceCount].to_i == 0 ? 'no' : params[:mainspaceCount]} edit#{'s' if params[:mainspaceCount].to_i != 1} in the [[WP:MAINSPACE|mainspace]]"
    end
  end

  def self.messageCompiler(requestData)
    str = ""

    if index = requestData.index{|obj| obj[:type] == :autoformat}
      requestData.delete_at(index)
      str = "#{COMMENT_INDENT}<small>#{COMMENT_PREFIX}#{getMessage(:autoformat)} ~~~~</small>\n"
      return str if requestData.length == 0
    end

    if index = requestData.index{|obj| obj[:type] == :autorespond}
      str += "\n::#{requestData[index][:resolution]} (automated response): This user "
    else
      str += COMMENT_INDENT + COMMENT_PREFIX + "This user "
    end

    requestData.each_with_index do |data, index|
      type = data.delete(:type)
      str = str.chomp(", ") + " and " if index == requestData.length - 1 && requestData.length > 1
      str += getMessage(type, data) + ", "
    end

    str.chomp(", ") + ". ~~~~\n"
  end

  def self.removeHeaders(oldWikitext)
    return false unless oldWikitext

    headersMatch = oldWikitext.scan(/(^\=\=[^\=]*\=\=[^\=]*(\=\=\=\=[^\=]*\=\=\=\=\n\*.*rfplinks\|1=(.*)\}\}\n))/)

    if headersMatch.length > 0
      info("Extraneous headers detected")

      for match in headersMatch
        if match[2]
          oldWikitext.sub!(match[0], match[1])
          @headersRemoved[match[2]] = match[0].scan(/\=\=\s*(.*)\s*\=\=/)[0][0]
        end
      end
    end

    oldWikitext
  end

  def self.setPageProps
    if @fetchThrotte < 3
      sleep @fetchThrotte
      @fetchThrotte += 1
      info("Fetching page properties of [[#{@pageName}]]")
      begin
        @startTimestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        pageObj = @mw.custom_query(prop: 'info|revisions', titles: @pageName, rvprop: 'timestamp|content')[0][0]
        @baseTimestamp = pageObj.elements['revisions'][0].attributes['timestamp']
        return pageObj.elements['revisions'][0][0].to_s
      rescue => e
        warn("Unable to fetch page properties, reattmpt ##{@fetchThrotte}. Error: #{e.message}")
        return setPageProps
      end
    else
      error("Unable to fetch page properties, continuing to process next permission") and return false
    end
  end

  def self.debug(msg); @logger.debug("#{@permission.upcase} : #{msg}"); end
  def self.info(msg); @logger.info("#{@permission.upcase} : #{msg}"); end
  def self.warn(msg); @logger.warn("#{@permission.upcase} : #{msg}"); end
  def self.error(msg); @logger.error("#{@permission.upcase} : #{msg}"); end
end
