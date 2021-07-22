# "Invidious" (which is an alternative front-end to YouTube)
# Copyright (C) 2019  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "digest/md5"
require "file_utils"
require "kemal"
require "openssl/hmac"
require "option_parser"
require "pg"
require "sqlite3"
require "xml"
require "yaml"
require "compress/zip"
require "protodec/utils"
require "./invidious/helpers/*"
require "./invidious/*"
require "./invidious/channels/*"
require "./invidious/routes/**"
require "./invidious/jobs/**"

CONFIG   = Config.load
HMAC_KEY = CONFIG.hmac_key || Random::Secure.hex(32)

PG_DB           = DB.open CONFIG.database_url
ARCHIVE_URL     = URI.parse("https://archive.org")
LOGIN_URL       = URI.parse("https://accounts.google.com")
PUBSUB_URL      = URI.parse("https://pubsubhubbub.appspot.com")
REDDIT_URL      = URI.parse("https://www.reddit.com")
TEXTCAPTCHA_URL = URI.parse("https://textcaptcha.com")
YT_URL          = URI.parse("https://www.youtube.com")
HOST_URL        = make_host_url(Kemal.config)

CHARS_SAFE         = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
TEST_IDS           = {"AgbeGFYluEA", "BaW_jenozKc", "a9LDPn-MO4I", "ddFvjfvPnqk", "iqKdEhx-dD4"}
MAX_ITEMS_PER_PAGE = 1500

REQUEST_HEADERS_WHITELIST  = {"accept", "accept-encoding", "cache-control", "content-length", "if-none-match", "range"}
RESPONSE_HEADERS_BLACKLIST = {"access-control-allow-origin", "alt-svc", "server"}
HTTP_CHUNK_SIZE            = 10485760 # ~10MB

CURRENT_BRANCH  = {{ "#{`git branch | sed -n '/* /s///p'`.strip}" }}
CURRENT_COMMIT  = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit`.strip}" }}
CURRENT_VERSION = {{ "#{`git log -1 --format=%ci | awk '{print $1}' | sed s/-/./g`.strip}" }}

# This is used to determine the `?v=` on the end of file URLs (for cache busting). We
# only need to expire modified assets, so we can use this to find the last commit that changes
# any assets
ASSET_COMMIT = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit -- assets`.strip}" }}

SOFTWARE = {
  "name"    => "invidious",
  "version" => "#{CURRENT_VERSION}-#{CURRENT_COMMIT}",
  "branch"  => "#{CURRENT_BRANCH}",
}

YT_POOL = YoutubeConnectionPool.new(YT_URL, capacity: CONFIG.pool_size, timeout: 2.0, use_quic: CONFIG.use_quic)

# CLI
Kemal.config.extra_options do |parser|
  parser.banner = "Usage: invidious [arguments]"
  parser.on("-c THREADS", "--channel-threads=THREADS", "Number of threads for refreshing channels (default: #{CONFIG.channel_threads})") do |number|
    begin
      CONFIG.channel_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-f THREADS", "--feed-threads=THREADS", "Number of threads for refreshing feeds (default: #{CONFIG.feed_threads})") do |number|
    begin
      CONFIG.feed_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-o OUTPUT", "--output=OUTPUT", "Redirect output (default: #{CONFIG.output})") do |output|
    CONFIG.output = output
  end
  parser.on("-l LEVEL", "--log-level=LEVEL", "Log level, one of #{LogLevel.values} (default: #{CONFIG.log_level})") do |log_level|
    CONFIG.log_level = LogLevel.parse(log_level)
  end
  parser.on("-v", "--version", "Print version") do
    puts SOFTWARE.to_pretty_json
    exit
  end
end

Kemal::CLI.new ARGV

if CONFIG.output.upcase != "STDOUT"
  FileUtils.mkdir_p(File.dirname(CONFIG.output))
end
OUTPUT = CONFIG.output.upcase == "STDOUT" ? STDOUT : File.open(CONFIG.output, mode: "a")
LOGGER = Invidious::LogHandler.new(OUTPUT, CONFIG.log_level)

# Check table integrity
if CONFIG.check_tables
  check_enum(PG_DB, "privacy", PlaylistPrivacy)

  check_table(PG_DB, "channels", InvidiousChannel)
  check_table(PG_DB, "channel_videos", ChannelVideo)
  check_table(PG_DB, "playlists", InvidiousPlaylist)
  check_table(PG_DB, "playlist_videos", PlaylistVideo)
  check_table(PG_DB, "nonces", Nonce)
  check_table(PG_DB, "session_ids", SessionId)
  check_table(PG_DB, "users", User)
  check_table(PG_DB, "videos", Video)

  if CONFIG.cache_annotations
    check_table(PG_DB, "annotations", Annotation)
  end
end

# Start jobs

if CONFIG.channel_threads > 0
  Invidious::Jobs.register Invidious::Jobs::RefreshChannelsJob.new(PG_DB)
end

if CONFIG.feed_threads > 0
  Invidious::Jobs.register Invidious::Jobs::RefreshFeedsJob.new(PG_DB)
end

DECRYPT_FUNCTION = DecryptFunction.new(CONFIG.decrypt_polling)
if CONFIG.decrypt_polling
  Invidious::Jobs.register Invidious::Jobs::UpdateDecryptFunctionJob.new
end

if CONFIG.statistics_enabled
  Invidious::Jobs.register Invidious::Jobs::StatisticsRefreshJob.new(PG_DB, SOFTWARE)
end

if (CONFIG.use_pubsub_feeds.is_a?(Bool) && CONFIG.use_pubsub_feeds.as(Bool)) || (CONFIG.use_pubsub_feeds.is_a?(Int32) && CONFIG.use_pubsub_feeds.as(Int32) > 0)
  Invidious::Jobs.register Invidious::Jobs::SubscribeToFeedsJob.new(PG_DB, HMAC_KEY)
end

if CONFIG.popular_enabled
  Invidious::Jobs.register Invidious::Jobs::PullPopularVideosJob.new(PG_DB)
end

if CONFIG.captcha_key
  Invidious::Jobs.register Invidious::Jobs::BypassCaptchaJob.new
end

connection_channel = Channel({Bool, Channel(PQ::Notification)}).new(32)
Invidious::Jobs.register Invidious::Jobs::NotificationJob.new(connection_channel, CONFIG.database_url)

Invidious::Jobs.start_all

def popular_videos
  Invidious::Jobs::PullPopularVideosJob::POPULAR_VIDEOS.get
end

before_all do |env|
  preferences = begin
    Preferences.from_json(URI.decode_www_form(env.request.cookies["PREFS"]?.try &.value || "{}"))
  rescue
    Preferences.from_json("{}")
  end

  env.set "preferences", preferences
  env.response.headers["X-XSS-Protection"] = "1; mode=block"
  env.response.headers["X-Content-Type-Options"] = "nosniff"

  # Allow media resources to be loaded from google servers
  # TODO: check if *.youtube.com can be removed
  if CONFIG.disabled?("local") || !preferences.local
    extra_media_csp = " https://*.googlevideo.com:443 https://*.youtube.com:443"
  else
    extra_media_csp = ""
  end

  # Only allow the pages at /embed/* to be embedded
  if env.request.resource.starts_with?("/embed")
    frame_ancestors = "'self' http: https:"
  else
    frame_ancestors = "'none'"
  end

  # TODO: Remove style-src's 'unsafe-inline', requires to remove all
  # inline styles (<style> [..] </style>, style=" [..] ")
  env.response.headers["Content-Security-Policy"] = {
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self' data:",
    "connect-src 'self'",
    "manifest-src 'self'",
    "media-src 'self' blob:" + extra_media_csp,
    "child-src 'self' blob:",
    "frame-src 'self'",
    "frame-ancestors " + frame_ancestors,
  }.join("; ")

  env.response.headers["Referrer-Policy"] = "same-origin"

  # Ask the chrom*-based browsers to disable FLoC
  # See: https://blog.runcloud.io/google-floc/
  env.response.headers["Permissions-Policy"] = "interest-cohort=()"

  if (Kemal.config.ssl || CONFIG.https_only) && CONFIG.hsts
    env.response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains; preload"
  end

  next if {
            "/sb/",
            "/vi/",
            "/s_p/",
            "/yts/",
            "/ggpht/",
            "/api/manifest/",
            "/videoplayback",
            "/latest_version",
          }.any? { |r| env.request.resource.starts_with? r }

  if env.request.cookies.has_key? "SID"
    sid = env.request.cookies["SID"].value

    if sid.starts_with? "v1:"
      raise "Cannot use token as SID"
    end

    # Invidious users only have SID
    if !env.request.cookies.has_key? "SSID"
      if email = PG_DB.query_one?("SELECT email FROM session_ids WHERE id = $1", sid, as: String)
        user = PG_DB.query_one("SELECT * FROM users WHERE email = $1", email, as: User)
        csrf_token = generate_response(sid, {
          ":authorize_token",
          ":playlist_ajax",
          ":signout",
          ":subscription_ajax",
          ":token_ajax",
          ":watch_ajax",
        }, HMAC_KEY, PG_DB, 1.week)

        preferences = user.preferences
        env.set "preferences", preferences

        env.set "sid", sid
        env.set "csrf_token", csrf_token
        env.set "user", user
      end
    else
      headers = HTTP::Headers.new
      headers["Cookie"] = env.request.headers["Cookie"]

      begin
        user, sid = get_user(sid, headers, PG_DB, false)
        csrf_token = generate_response(sid, {
          ":authorize_token",
          ":playlist_ajax",
          ":signout",
          ":subscription_ajax",
          ":token_ajax",
          ":watch_ajax",
        }, HMAC_KEY, PG_DB, 1.week)

        preferences = user.preferences
        env.set "preferences", preferences

        env.set "sid", sid
        env.set "csrf_token", csrf_token
        env.set "user", user
      rescue ex
      end
    end
  end

  dark_mode = convert_theme(env.params.query["dark_mode"]?) || preferences.dark_mode.to_s
  thin_mode = env.params.query["thin_mode"]? || preferences.thin_mode.to_s
  thin_mode = thin_mode == "true"
  locale = env.params.query["hl"]? || preferences.locale

  preferences.dark_mode = dark_mode
  preferences.thin_mode = thin_mode
  preferences.locale = locale
  env.set "preferences", preferences

  current_page = env.request.path
  if env.request.query
    query = HTTP::Params.parse(env.request.query.not_nil!)

    if query["referer"]?
      query["referer"] = get_referer(env, "/")
    end

    current_page += "?#{query}"
  end

  env.set "current_page", URI.encode_www_form(current_page)
end

Invidious::Routing.get "/", Invidious::Routes::Misc, :home
Invidious::Routing.get "/privacy", Invidious::Routes::Misc, :privacy
Invidious::Routing.get "/licenses", Invidious::Routes::Misc, :licenses

Invidious::Routing.get "/channel/:ucid", Invidious::Routes::Channels, :home
Invidious::Routing.get "/channel/:ucid/home", Invidious::Routes::Channels, :home
Invidious::Routing.get "/channel/:ucid/videos", Invidious::Routes::Channels, :videos
Invidious::Routing.get "/channel/:ucid/playlists", Invidious::Routes::Channels, :playlists
Invidious::Routing.get "/channel/:ucid/community", Invidious::Routes::Channels, :community
Invidious::Routing.get "/channel/:ucid/about", Invidious::Routes::Channels, :about

["", "/videos", "/playlists", "/community", "/about"].each do |path|
  # /c/LinusTechTips
  Invidious::Routing.get "/c/:user#{path}", Invidious::Routes::Channels, :brand_redirect
  # /user/linustechtips | Not always the same as /c/
  Invidious::Routing.get "/user/:user#{path}", Invidious::Routes::Channels, :brand_redirect
  # /attribution_link?a=anything&u=/channel/UCZYTClx2T1of7BRZ86-8fow
  Invidious::Routing.get "/attribution_link#{path}", Invidious::Routes::Channels, :brand_redirect
  # /profile?user=linustechtips
  Invidious::Routing.get "/profile/#{path}", Invidious::Routes::Channels, :profile
end

Invidious::Routing.get "/watch", Invidious::Routes::Watch, :handle
Invidious::Routing.get "/watch/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/shorts/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/w/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/v/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/e/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/redirect", Invidious::Routes::Misc, :cross_instance_redirect

Invidious::Routing.get "/embed/", Invidious::Routes::Embed, :redirect
Invidious::Routing.get "/embed/:id", Invidious::Routes::Embed, :show

Invidious::Routing.get "/view_all_playlists", Invidious::Routes::Playlists, :index
Invidious::Routing.get "/create_playlist", Invidious::Routes::Playlists, :new
Invidious::Routing.post "/create_playlist", Invidious::Routes::Playlists, :create
Invidious::Routing.get "/subscribe_playlist", Invidious::Routes::Playlists, :subscribe
Invidious::Routing.get "/delete_playlist", Invidious::Routes::Playlists, :delete_page
Invidious::Routing.post "/delete_playlist", Invidious::Routes::Playlists, :delete
Invidious::Routing.get "/edit_playlist", Invidious::Routes::Playlists, :edit
Invidious::Routing.post "/edit_playlist", Invidious::Routes::Playlists, :update
Invidious::Routing.get "/add_playlist_items", Invidious::Routes::Playlists, :add_playlist_items_page
Invidious::Routing.post "/playlist_ajax", Invidious::Routes::Playlists, :playlist_ajax
Invidious::Routing.get "/playlist", Invidious::Routes::Playlists, :show
Invidious::Routing.get "/mix", Invidious::Routes::Playlists, :mix

Invidious::Routing.get "/opensearch.xml", Invidious::Routes::Search, :opensearch
Invidious::Routing.get "/results", Invidious::Routes::Search, :results
Invidious::Routing.get "/search", Invidious::Routes::Search, :search

Invidious::Routing.get "/login", Invidious::Routes::Login, :login_page
Invidious::Routing.post "/login", Invidious::Routes::Login, :login
Invidious::Routing.post "/signout", Invidious::Routes::Login, :signout

Invidious::Routing.get "/preferences", Invidious::Routes::PreferencesRoute, :show
Invidious::Routing.post "/preferences", Invidious::Routes::PreferencesRoute, :update
Invidious::Routing.get "/toggle_theme", Invidious::Routes::PreferencesRoute, :toggle_theme

# Feeds
Invidious::Routing.get "/feed/playlists", Invidious::Routes::Feeds, :playlists
Invidious::Routing.get "/feed/popular", Invidious::Routes::Feeds, :popular
Invidious::Routing.get "/feed/trending", Invidious::Routes::Feeds, :trending
Invidious::Routing.get "/feed/subscriptions", Invidious::Routes::Feeds, :subscriptions
Invidious::Routing.get "/feed/history", Invidious::Routes::Feeds, :history

# RSS Feeds
Invidious::Routing.get "/feed/channel/:ucid", Invidious::Routes::Feeds, :rss_channel
Invidious::Routing.get "/feed/private", Invidious::Routes::Feeds, :rss_private
Invidious::Routing.get "/feed/playlist/:plid", Invidious::Routes::Feeds, :rss_playlist
Invidious::Routing.get "/feeds/videos.xml", Invidious::Routes::Feeds, :rss_videos
Invidious::Routing.get "/feed/webhook/:token", Invidious::Routes::Feeds, :push_notifications_get
Invidious::Routing.post "/feed/webhook/:token", Invidious::Routes::Feeds, :push_notifications_post

# Users

post "/watch_ajax" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/feed/subscriptions")

  redirect = env.params.query["redirect"]?
  redirect ||= "true"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  id = env.params.query["id"]?
  if !id
    env.response.status_code = 400
    next
  end

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    if redirect
      next error_template(400, ex)
    else
      next error_json(400, ex)
    end
  end

  if env.params.query["action_mark_watched"]?
    action = "action_mark_watched"
  elsif env.params.query["action_mark_unwatched"]?
    action = "action_mark_unwatched"
  else
    next env.redirect referer
  end

  case action
  when "action_mark_watched"
    if !user.watched.includes? id
      PG_DB.exec("UPDATE users SET watched = array_append(watched, $1) WHERE email = $2", id, user.email)
    end
  when "action_mark_unwatched"
    PG_DB.exec("UPDATE users SET watched = array_remove(watched, $1) WHERE email = $2", id, user.email)
  else
    next error_json(400, "Unsupported action #{action}")
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

# /modify_notifications
# will "ding" all subscriptions.
# /modify_notifications?receive_all_updates=false&receive_no_updates=false
# will "unding" all subscriptions.
get "/modify_notifications" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/")

  redirect = env.params.query["redirect"]?
  redirect ||= "false"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)

  if !user.password
    channel_req = {} of String => String

    channel_req["receive_all_updates"] = env.params.query["receive_all_updates"]? || "true"
    channel_req["receive_no_updates"] = env.params.query["receive_no_updates"]? || ""
    channel_req["receive_post_updates"] = env.params.query["receive_post_updates"]? || "true"

    channel_req.reject! { |k, v| v != "true" && v != "false" }

    headers = HTTP::Headers.new
    headers["Cookie"] = env.request.headers["Cookie"]

    html = YT_POOL.client &.get("/subscription_manager?disable_polymer=1", headers)

    cookies = HTTP::Cookies.from_client_headers(headers)
    html.cookies.each do |cookie|
      if {"VISITOR_INFO1_LIVE", "YSC", "SIDCC"}.includes? cookie.name
        if cookies[cookie.name]?
          cookies[cookie.name] = cookie
        else
          cookies << cookie
        end
      end
    end
    headers = cookies.add_request_headers(headers)

    if match = html.body.match(/'XSRF_TOKEN': "(?<session_token>[^"]+)"/)
      session_token = match["session_token"]
    else
      next env.redirect referer
    end

    headers["content-type"] = "application/x-www-form-urlencoded"
    channel_req["session_token"] = session_token

    subs = XML.parse_html(html.body)
    subs.xpath_nodes(%q(//a[@class="subscription-title yt-uix-sessionlink"]/@href)).each do |channel|
      channel_id = channel.content.lstrip("/channel/").not_nil!
      channel_req["channel_id"] = channel_id

      YT_POOL.client &.post("/subscription_ajax?action_update_subscription_preferences=1", headers, form: channel_req)
    end
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

post "/subscription_ajax" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/")

  redirect = env.params.query["redirect"]?
  redirect ||= "true"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    if redirect
      next error_template(400, ex)
    else
      next error_json(400, ex)
    end
  end

  if env.params.query["action_create_subscription_to_channel"]?.try &.to_i?.try &.== 1
    action = "action_create_subscription_to_channel"
  elsif env.params.query["action_remove_subscriptions"]?.try &.to_i?.try &.== 1
    action = "action_remove_subscriptions"
  else
    next env.redirect referer
  end

  channel_id = env.params.query["c"]?
  channel_id ||= ""

  if !user.password
    # Sync subscriptions with YouTube
    subscribe_ajax(channel_id, action, env.request.headers)
  end
  email = user.email

  case action
  when "action_create_subscription_to_channel"
    if !user.subscriptions.includes? channel_id
      get_channel(channel_id, PG_DB, false, false)
      PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_append(subscriptions, $1) WHERE email = $2", channel_id, email)
    end
  when "action_remove_subscriptions"
    PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_remove(subscriptions, $1) WHERE email = $2", channel_id, email)
  else
    next error_json(400, "Unsupported action #{action}")
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

get "/subscription_manager" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)

  if !user.password
    # Refresh account
    headers = HTTP::Headers.new
    headers["Cookie"] = env.request.headers["Cookie"]

    user, sid = get_user(sid, headers, PG_DB)
  end

  action_takeout = env.params.query["action_takeout"]?.try &.to_i?
  action_takeout ||= 0
  action_takeout = action_takeout == 1

  format = env.params.query["format"]?
  format ||= "rss"

  if user.subscriptions.empty?
    values = "'{}'"
  else
    values = "VALUES #{user.subscriptions.map { |id| %(('#{id}')) }.join(",")}"
  end

  subscriptions = PG_DB.query_all("SELECT * FROM channels WHERE id = ANY(#{values})", as: InvidiousChannel)
  subscriptions.sort_by! { |channel| channel.author.downcase }

  if action_takeout
    if format == "json"
      env.response.content_type = "application/json"
      env.response.headers["content-disposition"] = "attachment"
      playlists = PG_DB.query_all("SELECT * FROM playlists WHERE author = $1 AND id LIKE 'IV%' ORDER BY created", user.email, as: InvidiousPlaylist)

      next JSON.build do |json|
        json.object do
          json.field "subscriptions", user.subscriptions
          json.field "watch_history", user.watched
          json.field "preferences", user.preferences
          json.field "playlists" do
            json.array do
              playlists.each do |playlist|
                json.object do
                  json.field "title", playlist.title
                  json.field "description", html_to_content(playlist.description_html)
                  json.field "privacy", playlist.privacy.to_s
                  json.field "videos" do
                    json.array do
                      PG_DB.query_all("SELECT id FROM playlist_videos WHERE plid = $1 ORDER BY array_position($2, index) LIMIT 500", playlist.id, playlist.index, as: String).each do |video_id|
                        json.string video_id
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    else
      env.response.content_type = "application/xml"
      env.response.headers["content-disposition"] = "attachment"
      export = XML.build do |xml|
        xml.element("opml", version: "1.1") do
          xml.element("body") do
            if format == "newpipe"
              title = "YouTube Subscriptions"
            else
              title = "Invidious Subscriptions"
            end

            xml.element("outline", text: title, title: title) do
              subscriptions.each do |channel|
                if format == "newpipe"
                  xmlUrl = "https://www.youtube.com/feeds/videos.xml?channel_id=#{channel.id}"
                else
                  xmlUrl = "#{HOST_URL}/feed/channel/#{channel.id}"
                end

                xml.element("outline", text: channel.author, title: channel.author,
                  "type": "rss", xmlUrl: xmlUrl)
              end
            end
          end
        end
      end

      next export.gsub(%(<?xml version="1.0"?>\n), "")
    end
  end

  templated "subscription_manager"
end

get "/data_control" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)

  templated "data_control"
end

post "/data_control" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  referer = get_referer(env)

  if user
    user = user.as(User)

    # TODO: Find a way to prevent browser timeout

    HTTP::FormData.parse(env.request) do |part|
      body = part.body.gets_to_end
      next if body.empty?

      # TODO: Unify into single import based on content-type
      case part.name
      when "import_invidious"
        body = JSON.parse(body)

        if body["subscriptions"]?
          user.subscriptions += body["subscriptions"].as_a.map { |a| a.as_s }
          user.subscriptions.uniq!

          user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

          PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
        end

        if body["watch_history"]?
          user.watched += body["watch_history"].as_a.map { |a| a.as_s }
          user.watched.uniq!
          PG_DB.exec("UPDATE users SET watched = $1 WHERE email = $2", user.watched, user.email)
        end

        if body["preferences"]?
          user.preferences = Preferences.from_json(body["preferences"].to_json)
          PG_DB.exec("UPDATE users SET preferences = $1 WHERE email = $2", user.preferences.to_json, user.email)
        end

        if playlists = body["playlists"]?.try &.as_a?
          playlists.each do |item|
            title = item["title"]?.try &.as_s?.try &.delete("<>")
            description = item["description"]?.try &.as_s?.try &.delete("\r")
            privacy = item["privacy"]?.try &.as_s?.try { |privacy| PlaylistPrivacy.parse? privacy }

            next if !title
            next if !description
            next if !privacy

            playlist = create_playlist(PG_DB, title, privacy, user)
            PG_DB.exec("UPDATE playlists SET description = $1 WHERE id = $2", description, playlist.id)

            videos = item["videos"]?.try &.as_a?.try &.each_with_index do |video_id, idx|
              raise InfoException.new("Playlist cannot have more than 500 videos") if idx > 500

              video_id = video_id.try &.as_s?
              next if !video_id

              begin
                video = get_video(video_id, PG_DB)
              rescue ex
                next
              end

              playlist_video = PlaylistVideo.new({
                title:          video.title,
                id:             video.id,
                author:         video.author,
                ucid:           video.ucid,
                length_seconds: video.length_seconds,
                published:      video.published,
                plid:           playlist.id,
                live_now:       video.live_now,
                index:          Random::Secure.rand(0_i64..Int64::MAX),
              })

              video_array = playlist_video.to_a
              args = arg_array(video_array)

              PG_DB.exec("INSERT INTO playlist_videos VALUES (#{args})", args: video_array)
              PG_DB.exec("UPDATE playlists SET index = array_append(index, $1), video_count = cardinality(index) + 1, updated = $2 WHERE id = $3", playlist_video.index, Time.utc, playlist.id)
            end
          end
        end
      when "import_youtube"
        if body[0..4] == "<opml"
          subscriptions = XML.parse(body)
          user.subscriptions += subscriptions.xpath_nodes(%q(//outline[@type="rss"])).map do |channel|
            channel["xmlUrl"].match(/UC[a-zA-Z0-9_-]{22}/).not_nil![0]
          end
        else
          subscriptions = JSON.parse(body)
          user.subscriptions += subscriptions.as_a.compact_map do |entry|
            entry["snippet"]["resourceId"]["channelId"].as_s
          end
        end
        user.subscriptions.uniq!

        user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

        PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
      when "import_freetube"
        user.subscriptions += body.scan(/"channelId":"(?<channel_id>[a-zA-Z0-9_-]{24})"/).map do |md|
          md["channel_id"]
        end
        user.subscriptions.uniq!

        user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

        PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
      when "import_newpipe_subscriptions"
        body = JSON.parse(body)
        user.subscriptions += body["subscriptions"].as_a.compact_map do |channel|
          if match = channel["url"].as_s.match(/\/channel\/(?<channel>UC[a-zA-Z0-9_-]{22})/)
            next match["channel"]
          elsif match = channel["url"].as_s.match(/\/user\/(?<user>.+)/)
            response = YT_POOL.client &.get("/user/#{match["user"]}?disable_polymer=1&hl=en&gl=US")
            html = XML.parse_html(response.body)
            ucid = html.xpath_node(%q(//link[@rel="canonical"])).try &.["href"].split("/")[-1]
            next ucid if ucid
          end

          nil
        end
        user.subscriptions.uniq!

        user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

        PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
      when "import_newpipe"
        Compress::Zip::Reader.open(IO::Memory.new(body)) do |file|
          file.each_entry do |entry|
            if entry.filename == "newpipe.db"
              tempfile = File.tempfile(".db")
              File.write(tempfile.path, entry.io.gets_to_end)
              db = DB.open("sqlite3://" + tempfile.path)

              user.watched += db.query_all("SELECT url FROM streams", as: String).map { |url| url.lchop("https://www.youtube.com/watch?v=") }
              user.watched.uniq!

              PG_DB.exec("UPDATE users SET watched = $1 WHERE email = $2", user.watched, user.email)

              user.subscriptions += db.query_all("SELECT url FROM subscriptions", as: String).map { |url| url.lchop("https://www.youtube.com/channel/") }
              user.subscriptions.uniq!

              user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

              PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)

              db.close
              tempfile.delete
            end
          end
        end
      else nil # Ignore
      end
    end
  end

  env.redirect referer
end

get "/change_password" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":change_password"}, HMAC_KEY, PG_DB)

  templated "change_password"
end

post "/change_password" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  # We don't store passwords for Google accounts
  if !user.password
    next error_template(400, "Cannot change password for Google accounts")
  end

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  password = env.params.body["password"]?
  if !password
    next error_template(401, "Password is a required field")
  end

  new_passwords = env.params.body.select { |k, v| k.match(/^new_password\[\d+\]$/) }.map { |k, v| v }

  if new_passwords.size <= 1 || new_passwords.uniq.size != 1
    next error_template(400, "New passwords must match")
  end

  new_password = new_passwords.uniq[0]
  if new_password.empty?
    next error_template(401, "Password cannot be empty")
  end

  if new_password.bytesize > 55
    next error_template(400, "Password cannot be longer than 55 characters")
  end

  if !Crypto::Bcrypt::Password.new(user.password.not_nil!).verify(password.byte_slice(0, 55))
    next error_template(401, "Incorrect password")
  end

  new_password = Crypto::Bcrypt::Password.create(new_password, cost: 10)
  PG_DB.exec("UPDATE users SET password = $1 WHERE email = $2", new_password.to_s, user.email)

  env.redirect referer
end

get "/delete_account" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":delete_account"}, HMAC_KEY, PG_DB)

  templated "delete_account"
end

post "/delete_account" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  view_name = "subscriptions_#{sha256(user.email)}"
  PG_DB.exec("DELETE FROM users * WHERE email = $1", user.email)
  PG_DB.exec("DELETE FROM session_ids * WHERE email = $1", user.email)
  PG_DB.exec("DROP MATERIALIZED VIEW #{view_name}")

  env.request.cookies.each do |cookie|
    cookie.expires = Time.utc(1990, 1, 1)
    env.response.cookies << cookie
  end

  env.redirect referer
end

get "/clear_watch_history" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":clear_watch_history"}, HMAC_KEY, PG_DB)

  templated "clear_watch_history"
end

post "/clear_watch_history" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  PG_DB.exec("UPDATE users SET watched = '{}' WHERE email = $1", user.email)
  env.redirect referer
end

get "/authorize_token" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":authorize_token"}, HMAC_KEY, PG_DB)

  scopes = env.params.query["scopes"]?.try &.split(",")
  scopes ||= [] of String

  callback_url = env.params.query["callback_url"]?
  if callback_url
    callback_url = URI.parse(callback_url)
  end

  expire = env.params.query["expire"]?.try &.to_i?

  templated "authorize_token"
end

post "/authorize_token" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = env.get("user").as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  scopes = env.params.body.select { |k, v| k.match(/^scopes\[\d+\]$/) }.map { |k, v| v }
  callback_url = env.params.body["callbackUrl"]?
  expire = env.params.body["expire"]?.try &.to_i?

  access_token = generate_token(user.email, scopes, expire, HMAC_KEY, PG_DB)

  if callback_url
    access_token = URI.encode_www_form(access_token)
    url = URI.parse(callback_url)

    if url.query
      query = HTTP::Params.parse(url.query.not_nil!)
    else
      query = HTTP::Params.new
    end

    query["token"] = access_token
    url.query = query.to_s

    env.redirect url.to_s
  else
    csrf_token = ""
    env.set "access_token", access_token
    templated "authorize_token"
  end
end

get "/token_manager" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/subscription_manager")

  if !user
    next env.redirect referer
  end

  user = user.as(User)

  tokens = PG_DB.query_all("SELECT id, issued FROM session_ids WHERE email = $1 ORDER BY issued DESC", user.email, as: {session: String, issued: Time})

  templated "token_manager"
end

post "/token_ajax" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  redirect = env.params.query["redirect"]?
  redirect ||= "true"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    if redirect
      next error_template(400, ex)
    else
      next error_json(400, ex)
    end
  end

  if env.params.query["action_revoke_token"]?
    action = "action_revoke_token"
  else
    next env.redirect referer
  end

  session = env.params.query["session"]?
  session ||= ""

  case action
  when .starts_with? "action_revoke_token"
    PG_DB.exec("DELETE FROM session_ids * WHERE id = $1 AND email = $2", session, user.email)
  else
    next error_json(400, "Unsupported action #{action}")
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

# Channels

{"/channel/:ucid/live", "/user/:user/live", "/c/:user/live"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    # Appears to be a bug in routing, having several routes configured
    # as `/a/:a`, `/b/:a`, `/c/:a` results in 404
    value = env.request.resource.split("/")[2]
    body = ""
    {"channel", "user", "c"}.each do |type|
      response = YT_POOL.client &.get("/#{type}/#{value}/live?disable_polymer=1")
      if response.status_code == 200
        body = response.body
      end
    end

    video_id = body.match(/'VIDEO_ID': "(?<id>[a-zA-Z0-9_-]{11})"/).try &.["id"]?
    if video_id
      params = [] of String
      env.params.query.each do |k, v|
        params << "#{k}=#{v}"
      end
      params = params.join("&")

      url = "/watch?v=#{video_id}"
      if !params.empty?
        url += "&#{params}"
      end

      env.redirect url
    else
      env.redirect "/channel/#{value}"
    end
  end
end

# API Endpoints

get "/api/v1/stats" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  env.response.content_type = "application/json"

  if !CONFIG.statistics_enabled
    next error_json(400, "Statistics are not enabled.")
  end

  Invidious::Jobs::StatisticsRefreshJob::STATISTICS.to_json
end

# YouTube provides "storyboards", which are sprites containing x * y
# preview thumbnails for individual scenes in a video.
# See https://support.jwplayer.com/articles/how-to-add-preview-thumbnails
get "/api/v1/storyboards/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  begin
    video = get_video(id, PG_DB, region: region)
  rescue ex : VideoRedirect
    env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
    next error_json(302, "Video is unavailable", {"videoId" => ex.video_id})
  rescue ex
    env.response.status_code = 500
    next
  end

  storyboards = video.storyboards
  width = env.params.query["width"]?
  height = env.params.query["height"]?

  if !width && !height
    response = JSON.build do |json|
      json.object do
        json.field "storyboards" do
          generate_storyboards(json, id, storyboards)
        end
      end
    end

    next response
  end

  env.response.content_type = "text/vtt"

  storyboard = storyboards.select { |storyboard| width == "#{storyboard[:width]}" || height == "#{storyboard[:height]}" }

  if storyboard.empty?
    env.response.status_code = 404
    next
  else
    storyboard = storyboard[0]
  end

  String.build do |str|
    str << <<-END_VTT
    WEBVTT


    END_VTT

    start_time = 0.milliseconds
    end_time = storyboard[:interval].milliseconds

    storyboard[:storyboard_count].times do |i|
      url = storyboard[:url]
      authority = /(i\d?).ytimg.com/.match(url).not_nil![1]?
      url = url.gsub("$M", i).gsub(%r(https://i\d?.ytimg.com/sb/), "")
      url = "#{HOST_URL}/sb/#{authority}/#{url}"

      storyboard[:storyboard_height].times do |j|
        storyboard[:storyboard_width].times do |k|
          str << <<-END_CUE
          #{start_time}.000 --> #{end_time}.000
          #{url}#xywh=#{storyboard[:width] * k},#{storyboard[:height] * j},#{storyboard[:width] - 2},#{storyboard[:height]}


          END_CUE

          start_time += storyboard[:interval].milliseconds
          end_time += storyboard[:interval].milliseconds
        end
      end
    end
  end
end

get "/api/v1/captions/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  # See https://github.com/ytdl-org/youtube-dl/blob/6ab30ff50bf6bd0585927cb73c7421bef184f87a/youtube_dl/extractor/youtube.py#L1354
  # It is possible to use `/api/timedtext?type=list&v=#{id}` and
  # `/api/timedtext?type=track&v=#{id}&lang=#{lang_code}` directly,
  # but this does not provide links for auto-generated captions.
  #
  # In future this should be investigated as an alternative, since it does not require
  # getting video info.

  begin
    video = get_video(id, PG_DB, region: region)
  rescue ex : VideoRedirect
    env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
    next error_json(302, "Video is unavailable", {"videoId" => ex.video_id})
  rescue ex
    env.response.status_code = 500
    next
  end

  captions = video.captions

  label = env.params.query["label"]?
  lang = env.params.query["lang"]?
  tlang = env.params.query["tlang"]?

  if !label && !lang
    response = JSON.build do |json|
      json.object do
        json.field "captions" do
          json.array do
            captions.each do |caption|
              json.object do
                json.field "label", caption.name
                json.field "languageCode", caption.languageCode
                json.field "url", "/api/v1/captions/#{id}?label=#{URI.encode_www_form(caption.name)}"
              end
            end
          end
        end
      end
    end

    next response
  end

  env.response.content_type = "text/vtt; charset=UTF-8"

  if lang
    caption = captions.select { |caption| caption.languageCode == lang }
  else
    caption = captions.select { |caption| caption.name == label }
  end

  if caption.empty?
    env.response.status_code = 404
    next
  else
    caption = caption[0]
  end

  url = URI.parse("#{caption.baseUrl}&tlang=#{tlang}").request_target

  # Auto-generated captions often have cues that aren't aligned properly with the video,
  # as well as some other markup that makes it cumbersome, so we try to fix that here
  if caption.name.includes? "auto-generated"
    caption_xml = YT_POOL.client &.get(url).body
    caption_xml = XML.parse(caption_xml)

    webvtt = String.build do |str|
      str << <<-END_VTT
      WEBVTT
      Kind: captions
      Language: #{tlang || caption.languageCode}


      END_VTT

      caption_nodes = caption_xml.xpath_nodes("//transcript/text")
      caption_nodes.each_with_index do |node, i|
        start_time = node["start"].to_f.seconds
        duration = node["dur"]?.try &.to_f.seconds
        duration ||= start_time

        if caption_nodes.size > i + 1
          end_time = caption_nodes[i + 1]["start"].to_f.seconds
        else
          end_time = start_time + duration
        end

        start_time = "#{start_time.hours.to_s.rjust(2, '0')}:#{start_time.minutes.to_s.rjust(2, '0')}:#{start_time.seconds.to_s.rjust(2, '0')}.#{start_time.milliseconds.to_s.rjust(3, '0')}"
        end_time = "#{end_time.hours.to_s.rjust(2, '0')}:#{end_time.minutes.to_s.rjust(2, '0')}:#{end_time.seconds.to_s.rjust(2, '0')}.#{end_time.milliseconds.to_s.rjust(3, '0')}"

        text = HTML.unescape(node.content)
        text = text.gsub(/<font color="#[a-fA-F0-9]{6}">/, "")
        text = text.gsub(/<\/font>/, "")
        if md = text.match(/(?<name>.*) : (?<text>.*)/)
          text = "<v #{md["name"]}>#{md["text"]}</v>"
        end

        str << <<-END_CUE
        #{start_time} --> #{end_time}
        #{text}


        END_CUE
      end
    end
  else
    webvtt = YT_POOL.client &.get("#{url}&format=vtt").body
  end

  if title = env.params.query["title"]?
    # https://blog.fastmail.com/2011/06/24/download-non-english-filenames/
    env.response.headers["Content-Disposition"] = "attachment; filename=\"#{URI.encode_www_form(title)}\"; filename*=UTF-8''#{URI.encode_www_form(title)}"
  end

  webvtt
end

get "/api/v1/comments/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]

  source = env.params.query["source"]?
  source ||= "youtube"

  thin_mode = env.params.query["thin_mode"]?
  thin_mode = thin_mode == "true"

  format = env.params.query["format"]?
  format ||= "json"

  continuation = env.params.query["continuation"]?
  sort_by = env.params.query["sort_by"]?.try &.downcase

  if source == "youtube"
    sort_by ||= "top"

    begin
      comments = fetch_youtube_comments(id, continuation, format, locale, thin_mode, region, sort_by: sort_by)
    rescue ex
      next error_json(500, ex)
    end

    next comments
  elsif source == "reddit"
    sort_by ||= "confidence"

    begin
      comments, reddit_thread = fetch_reddit_comments(id, sort_by: sort_by)
      content_html = template_reddit_comments(comments, locale)

      content_html = fill_links(content_html, "https", "www.reddit.com")
      content_html = replace_links(content_html)
    rescue ex
      comments = nil
      reddit_thread = nil
      content_html = ""
    end

    if !reddit_thread || !comments
      env.response.status_code = 404
      next
    end

    if format == "json"
      reddit_thread = JSON.parse(reddit_thread.to_json).as_h
      reddit_thread["comments"] = JSON.parse(comments.to_json)

      next reddit_thread.to_json
    else
      response = {
        "title"       => reddit_thread.title,
        "permalink"   => reddit_thread.permalink,
        "contentHtml" => content_html,
      }

      next response.to_json
    end
  end
end

get "/api/v1/insights/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  next error_json(410, "YouTube has removed publicly available analytics.")
end

get "/api/v1/annotations/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "text/xml"

  id = env.params.url["id"]
  source = env.params.query["source"]?
  source ||= "archive"

  if !id.match(/[a-zA-Z0-9_-]{11}/)
    env.response.status_code = 400
    next
  end

  annotations = ""

  case source
  when "archive"
    if CONFIG.cache_annotations && (cached_annotation = PG_DB.query_one?("SELECT * FROM annotations WHERE id = $1", id, as: Annotation))
      annotations = cached_annotation.annotations
    else
      index = CHARS_SAFE.index(id[0]).not_nil!.to_s.rjust(2, '0')

      # IA doesn't handle leading hyphens,
      # so we use https://archive.org/details/youtubeannotations_64
      if index == "62"
        index = "64"
        id = id.sub(/^-/, 'A')
      end

      file = URI.encode_www_form("#{id[0, 3]}/#{id}.xml")

      location = make_client(ARCHIVE_URL, &.get("/download/youtubeannotations_#{index}/#{id[0, 2]}.tar/#{file}"))

      if !location.headers["Location"]?
        env.response.status_code = location.status_code
      end

      response = make_client(URI.parse(location.headers["Location"]), &.get(location.headers["Location"]))

      if response.body.empty?
        env.response.status_code = 404
        next
      end

      if response.status_code != 200
        env.response.status_code = response.status_code
        next
      end

      annotations = response.body

      cache_annotation(PG_DB, id, annotations)
    end
  else # "youtube"
    response = YT_POOL.client &.get("/annotations_invideo?video_id=#{id}")

    if response.status_code != 200
      env.response.status_code = response.status_code
      next
    end

    annotations = response.body
  end

  etag = sha256(annotations)[0, 16]
  if env.request.headers["If-None-Match"]?.try &.== etag
    env.response.status_code = 304
  else
    env.response.headers["ETag"] = etag
    annotations
  end
end

get "/api/v1/videos/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  begin
    video = get_video(id, PG_DB, region: region)
  rescue ex : VideoRedirect
    env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
    next error_json(302, "Video is unavailable", {"videoId" => ex.video_id})
  rescue ex
    next error_json(500, ex)
  end

  video.to_json(locale)
end

get "/api/v1/trending" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  region = env.params.query["region"]?
  trending_type = env.params.query["type"]?

  begin
    trending, plid = fetch_trending(trending_type, region, locale)
  rescue ex
    next error_json(500, ex)
  end

  videos = JSON.build do |json|
    json.array do
      trending.each do |video|
        video.to_json(locale, json)
      end
    end
  end

  videos
end

get "/api/v1/popular" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  if !CONFIG.popular_enabled
    error_message = {"error" => "Administrator has disabled this endpoint."}.to_json
    env.response.status_code = 400
    next error_message
  end

  JSON.build do |json|
    json.array do
      popular_videos.each do |video|
        video.to_json(locale, json)
      end
    end
  end
end

get "/api/v1/top" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  env.response.status_code = 400
  {"error" => "The Top feed has been removed from Invidious."}.to_json
end

get "/api/v1/channels/:ucid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  ucid = env.params.url["ucid"]
  sort_by = env.params.query["sort_by"]?.try &.downcase
  sort_by ||= "newest"

  begin
    channel = get_about_info(ucid, locale)
  rescue ex : ChannelRedirect
    env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
    next error_json(302, "Channel is unavailable", {"authorId" => ex.channel_id})
  rescue ex
    next error_json(500, ex)
  end

  page = 1
  if channel.auto_generated
    videos = [] of SearchVideo
    count = 0
  else
    begin
      count, videos = get_60_videos(channel.ucid, channel.author, page, channel.auto_generated, sort_by)
    rescue ex
      next error_json(500, ex)
    end
  end

  JSON.build do |json|
    # TODO: Refactor into `to_json` for InvidiousChannel
    json.object do
      json.field "author", channel.author
      json.field "authorId", channel.ucid
      json.field "authorUrl", channel.author_url

      json.field "authorBanners" do
        json.array do
          if channel.banner
            qualities = {
              {width: 2560, height: 424},
              {width: 2120, height: 351},
              {width: 1060, height: 175},
            }
            qualities.each do |quality|
              json.object do
                json.field "url", channel.banner.not_nil!.gsub("=w1060-", "=w#{quality[:width]}-")
                json.field "width", quality[:width]
                json.field "height", quality[:height]
              end
            end

            json.object do
              json.field "url", channel.banner.not_nil!.split("=w1060-")[0]
              json.field "width", 512
              json.field "height", 288
            end
          end
        end
      end

      json.field "authorThumbnails" do
        json.array do
          qualities = {32, 48, 76, 100, 176, 512}

          qualities.each do |quality|
            json.object do
              json.field "url", channel.author_thumbnail.gsub(/=s\d+/, "=s#{quality}")
              json.field "width", quality
              json.field "height", quality
            end
          end
        end
      end

      json.field "subCount", channel.sub_count
      json.field "totalViews", channel.total_views
      json.field "joined", channel.joined.to_unix

      json.field "autoGenerated", channel.auto_generated
      json.field "isFamilyFriendly", channel.is_family_friendly
      json.field "description", html_to_content(channel.description_html)
      json.field "descriptionHtml", channel.description_html

      json.field "allowedRegions", channel.allowed_regions

      json.field "latestVideos" do
        json.array do
          videos.each do |video|
            video.to_json(locale, json)
          end
        end
      end

      json.field "relatedChannels" do
        json.array do
          channel.related_channels.each do |related_channel|
            json.object do
              json.field "author", related_channel.author
              json.field "authorId", related_channel.ucid
              json.field "authorUrl", related_channel.author_url

              json.field "authorThumbnails" do
                json.array do
                  qualities = {32, 48, 76, 100, 176, 512}

                  qualities.each do |quality|
                    json.object do
                      json.field "url", related_channel.author_thumbnail.gsub(/=\d+/, "=s#{quality}")
                      json.field "width", quality
                      json.field "height", quality
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

{"/api/v1/channels/:ucid/videos", "/api/v1/channels/videos/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    page = env.params.query["page"]?.try &.to_i?
    page ||= 1
    sort_by = env.params.query["sort"]?.try &.downcase
    sort_by ||= env.params.query["sort_by"]?.try &.downcase
    sort_by ||= "newest"

    begin
      channel = get_about_info(ucid, locale)
    rescue ex : ChannelRedirect
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      next error_json(302, "Channel is unavailable", {"authorId" => ex.channel_id})
    rescue ex
      next error_json(500, ex)
    end

    begin
      count, videos = get_60_videos(channel.ucid, channel.author, page, channel.auto_generated, sort_by)
    rescue ex
      next error_json(500, ex)
    end

    JSON.build do |json|
      json.array do
        videos.each do |video|
          video.to_json(locale, json)
        end
      end
    end
  end
end

{"/api/v1/channels/:ucid/latest", "/api/v1/channels/latest/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    begin
      videos = get_latest_videos(ucid)
    rescue ex
      next error_json(500, ex)
    end

    JSON.build do |json|
      json.array do
        videos.each do |video|
          video.to_json(locale, json)
        end
      end
    end
  end
end

{"/api/v1/channels/:ucid/playlists", "/api/v1/channels/playlists/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]
    continuation = env.params.query["continuation"]?
    sort_by = env.params.query["sort"]?.try &.downcase ||
              env.params.query["sort_by"]?.try &.downcase ||
              "last"

    begin
      channel = get_about_info(ucid, locale)
    rescue ex : ChannelRedirect
      env.response.headers["Location"] = env.request.resource.gsub(ucid, ex.channel_id)
      next error_json(302, "Channel is unavailable", {"authorId" => ex.channel_id})
    rescue ex
      next error_json(500, ex)
    end

    items, continuation = fetch_channel_playlists(channel.ucid, channel.author, continuation, sort_by)

    JSON.build do |json|
      json.object do
        json.field "playlists" do
          json.array do
            items.each do |item|
              item.to_json(locale, json) if item.is_a?(SearchPlaylist)
            end
          end
        end

        json.field "continuation", continuation
      end
    end
  end
end

{"/api/v1/channels/:ucid/comments", "/api/v1/channels/comments/:ucid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"

    ucid = env.params.url["ucid"]

    thin_mode = env.params.query["thin_mode"]?
    thin_mode = thin_mode == "true"

    format = env.params.query["format"]?
    format ||= "json"

    continuation = env.params.query["continuation"]?
    # sort_by = env.params.query["sort_by"]?.try &.downcase

    begin
      fetch_channel_community(ucid, continuation, locale, format, thin_mode)
    rescue ex
      next error_json(500, ex)
    end
  end
end

get "/api/v1/channels/search/:ucid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  ucid = env.params.url["ucid"]

  query = env.params.query["q"]?
  query ||= ""

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  count, search_results = channel_search(query, page, ucid)
  JSON.build do |json|
    json.array do
      search_results.each do |item|
        item.to_json(locale, json)
      end
    end
  end
end

get "/api/v1/search" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  query = env.params.query["q"]?
  query ||= ""

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  sort_by = env.params.query["sort_by"]?.try &.downcase
  sort_by ||= "relevance"

  date = env.params.query["date"]?.try &.downcase
  date ||= ""

  duration = env.params.query["duration"]?.try &.downcase
  duration ||= ""

  features = env.params.query["features"]?.try &.split(",").map { |feature| feature.downcase }
  features ||= [] of String

  content_type = env.params.query["type"]?.try &.downcase
  content_type ||= "video"

  begin
    search_params = produce_search_params(page, sort_by, date, content_type, duration, features)
  rescue ex
    next error_json(400, ex)
  end

  count, search_results = search(query, search_params, region).as(Tuple)
  JSON.build do |json|
    json.array do
      search_results.each do |item|
        item.to_json(locale, json)
      end
    end
  end
end

get "/api/v1/search/suggestions" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  query = env.params.query["q"]?
  query ||= ""

  begin
    headers = HTTP::Headers{":authority" => "suggestqueries.google.com"}
    response = YT_POOL.client &.get("/complete/search?hl=en&gl=#{region}&client=youtube&ds=yt&q=#{URI.encode_www_form(query)}&callback=suggestCallback", headers).body

    body = response[35..-2]
    body = JSON.parse(body).as_a
    suggestions = body[1].as_a[0..-2]

    JSON.build do |json|
      json.object do
        json.field "query", body[0].as_s
        json.field "suggestions" do
          json.array do
            suggestions.each do |suggestion|
              json.string suggestion[0].as_s
            end
          end
        end
      end
    end
  rescue ex
    next error_json(500, ex)
  end
end

{"/api/v1/playlists/:plid", "/api/v1/auth/playlists/:plid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"
    plid = env.params.url["plid"]

    offset = env.params.query["index"]?.try &.to_i?
    offset ||= env.params.query["page"]?.try &.to_i?.try { |page| (page - 1) * 100 }
    offset ||= 0

    continuation = env.params.query["continuation"]?

    format = env.params.query["format"]?
    format ||= "json"

    if plid.starts_with? "RD"
      next env.redirect "/api/v1/mixes/#{plid}"
    end

    begin
      playlist = get_playlist(PG_DB, plid, locale)
    rescue ex : InfoException
      next error_json(404, ex)
    rescue ex
      next error_json(404, "Playlist does not exist.")
    end

    user = env.get?("user").try &.as(User)
    if !playlist || playlist.privacy.private? && playlist.author != user.try &.email
      next error_json(404, "Playlist does not exist.")
    end

    response = playlist.to_json(offset, locale, continuation: continuation)

    if format == "html"
      response = JSON.parse(response)
      playlist_html = template_playlist(response)
      index, next_video = response["videos"].as_a.skip(1).select { |video| !video["author"].as_s.empty? }[0]?.try { |v| {v["index"], v["videoId"]} } || {nil, nil}

      response = {
        "playlistHtml" => playlist_html,
        "index"        => index,
        "nextVideo"    => next_video,
      }.to_json
    end

    response
  end
end

get "/api/v1/mixes/:rdid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  rdid = env.params.url["rdid"]

  continuation = env.params.query["continuation"]?
  continuation ||= rdid.lchop("RD")[0, 11]

  format = env.params.query["format"]?
  format ||= "json"

  begin
    mix = fetch_mix(rdid, continuation, locale: locale)

    if !rdid.ends_with? continuation
      mix = fetch_mix(rdid, mix.videos[1].id)
      index = mix.videos.index(mix.videos.select { |video| video.id == continuation }[0]?)
    end

    mix.videos = mix.videos[index..-1]
  rescue ex
    next error_json(500, ex)
  end

  response = JSON.build do |json|
    json.object do
      json.field "title", mix.title
      json.field "mixId", mix.id

      json.field "videos" do
        json.array do
          mix.videos.each do |video|
            json.object do
              json.field "title", video.title
              json.field "videoId", video.id
              json.field "author", video.author

              json.field "authorId", video.ucid
              json.field "authorUrl", "/channel/#{video.ucid}"

              json.field "videoThumbnails" do
                json.array do
                  generate_thumbnails(json, video.id)
                end
              end

              json.field "index", video.index
              json.field "lengthSeconds", video.length_seconds
            end
          end
        end
      end
    end
  end

  if format == "html"
    response = JSON.parse(response)
    playlist_html = template_mix(response)
    next_video = response["videos"].as_a.select { |video| !video["author"].as_s.empty? }[0]?.try &.["videoId"]

    response = {
      "playlistHtml" => playlist_html,
      "nextVideo"    => next_video,
    }.to_json
  end

  response
end

# Authenticated endpoints

get "/api/v1/auth/notifications" do |env|
  env.response.content_type = "text/event-stream"

  topics = env.params.query["topics"]?.try &.split(",").uniq.first(1000)
  topics ||= [] of String

  create_notification_stream(env, topics, connection_channel)
end

post "/api/v1/auth/notifications" do |env|
  env.response.content_type = "text/event-stream"

  topics = env.params.body["topics"]?.try &.split(",").uniq.first(1000)
  topics ||= [] of String

  create_notification_stream(env, topics, connection_channel)
end

get "/api/v1/auth/preferences" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  user.preferences.to_json
end

post "/api/v1/auth/preferences" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  begin
    preferences = Preferences.from_json(env.request.body || "{}")
  rescue
    preferences = user.preferences
  end

  PG_DB.exec("UPDATE users SET preferences = $1 WHERE email = $2", preferences.to_json, user.email)

  env.response.status_code = 204
end

get "/api/v1/auth/feed" do |env|
  env.response.content_type = "application/json"

  user = env.get("user").as(User)
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  max_results = env.params.query["max_results"]?.try &.to_i?
  max_results ||= user.preferences.max_results
  max_results ||= CONFIG.default_user_preferences.max_results

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  videos, notifications = get_subscription_feed(PG_DB, user, max_results, page)

  JSON.build do |json|
    json.object do
      json.field "notifications" do
        json.array do
          notifications.each do |video|
            video.to_json(locale, json)
          end
        end
      end

      json.field "videos" do
        json.array do
          videos.each do |video|
            video.to_json(locale, json)
          end
        end
      end
    end
  end
end

get "/api/v1/auth/subscriptions" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  if user.subscriptions.empty?
    values = "'{}'"
  else
    values = "VALUES #{user.subscriptions.map { |id| %(('#{id}')) }.join(",")}"
  end

  subscriptions = PG_DB.query_all("SELECT * FROM channels WHERE id = ANY(#{values})", as: InvidiousChannel)

  JSON.build do |json|
    json.array do
      subscriptions.each do |subscription|
        json.object do
          json.field "author", subscription.author
          json.field "authorId", subscription.id
        end
      end
    end
  end
end

post "/api/v1/auth/subscriptions/:ucid" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  ucid = env.params.url["ucid"]

  if !user.subscriptions.includes? ucid
    get_channel(ucid, PG_DB, false, false)
    PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_append(subscriptions,$1) WHERE email = $2", ucid, user.email)
  end

  # For Google accounts, access tokens don't have enough information to
  # make a request on the user's behalf, which is why we don't sync with
  # YouTube.

  env.response.status_code = 204
end

delete "/api/v1/auth/subscriptions/:ucid" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  ucid = env.params.url["ucid"]

  PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_remove(subscriptions, $1) WHERE email = $2", ucid, user.email)

  env.response.status_code = 204
end

get "/api/v1/auth/playlists" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  playlists = PG_DB.query_all("SELECT * FROM playlists WHERE author = $1", user.email, as: InvidiousPlaylist)

  JSON.build do |json|
    json.array do
      playlists.each do |playlist|
        playlist.to_json(0, locale, json)
      end
    end
  end
end

post "/api/v1/auth/playlists" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  title = env.params.json["title"]?.try &.as(String).delete("<>").byte_slice(0, 150)
  if !title
    next error_json(400, "Invalid title.")
  end

  privacy = env.params.json["privacy"]?.try { |privacy| PlaylistPrivacy.parse(privacy.as(String).downcase) }
  if !privacy
    next error_json(400, "Invalid privacy setting.")
  end

  if PG_DB.query_one("SELECT count(*) FROM playlists WHERE author = $1", user.email, as: Int64) >= 100
    next error_json(400, "User cannot have more than 100 playlists.")
  end

  playlist = create_playlist(PG_DB, title, privacy, user)
  env.response.headers["Location"] = "#{HOST_URL}/api/v1/auth/playlists/#{playlist.id}"
  env.response.status_code = 201
  {
    "title"      => title,
    "playlistId" => playlist.id,
  }.to_json
end

patch "/api/v1/auth/playlists/:plid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  title = env.params.json["title"].try &.as(String).delete("<>").byte_slice(0, 150) || playlist.title
  privacy = env.params.json["privacy"]?.try { |privacy| PlaylistPrivacy.parse(privacy.as(String).downcase) } || playlist.privacy
  description = env.params.json["description"]?.try &.as(String).delete("\r") || playlist.description

  if title != playlist.title ||
     privacy != playlist.privacy ||
     description != playlist.description
    updated = Time.utc
  else
    updated = playlist.updated
  end

  PG_DB.exec("UPDATE playlists SET title = $1, privacy = $2, description = $3, updated = $4 WHERE id = $5", title, privacy, description, updated, plid)
  env.response.status_code = 204
end

delete "/api/v1/auth/playlists/:plid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  PG_DB.exec("DELETE FROM playlist_videos * WHERE plid = $1", plid)
  PG_DB.exec("DELETE FROM playlists * WHERE id = $1", plid)

  env.response.status_code = 204
end

post "/api/v1/auth/playlists/:plid/videos" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  if playlist.index.size >= 500
    next error_json(400, "Playlist cannot have more than 500 videos")
  end

  video_id = env.params.json["videoId"].try &.as(String)
  if !video_id
    next error_json(403, "Invalid videoId")
  end

  begin
    video = get_video(video_id, PG_DB)
  rescue ex
    next error_json(500, ex)
  end

  playlist_video = PlaylistVideo.new({
    title:          video.title,
    id:             video.id,
    author:         video.author,
    ucid:           video.ucid,
    length_seconds: video.length_seconds,
    published:      video.published,
    plid:           plid,
    live_now:       video.live_now,
    index:          Random::Secure.rand(0_i64..Int64::MAX),
  })

  video_array = playlist_video.to_a
  args = arg_array(video_array)

  PG_DB.exec("INSERT INTO playlist_videos VALUES (#{args})", args: video_array)
  PG_DB.exec("UPDATE playlists SET index = array_append(index, $1), video_count = cardinality(index) + 1, updated = $2 WHERE id = $3", playlist_video.index, Time.utc, plid)

  env.response.headers["Location"] = "#{HOST_URL}/api/v1/auth/playlists/#{plid}/videos/#{playlist_video.index.to_u64.to_s(16).upcase}"
  env.response.status_code = 201
  playlist_video.to_json(locale, index: playlist.index.size)
end

delete "/api/v1/auth/playlists/:plid/videos/:index" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]
  index = env.params.url["index"].to_i64(16)

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  if !playlist.index.includes? index
    next error_json(404, "Playlist does not contain index")
  end

  PG_DB.exec("DELETE FROM playlist_videos * WHERE index = $1", index)
  PG_DB.exec("UPDATE playlists SET index = array_remove(index, $1), video_count = cardinality(index) - 1, updated = $2 WHERE id = $3", index, Time.utc, plid)

  env.response.status_code = 204
end

# patch "/api/v1/auth/playlists/:plid/videos/:index" do |env|
# TODO: Playlist stub
# end

get "/api/v1/auth/tokens" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  scopes = env.get("scopes").as(Array(String))

  tokens = PG_DB.query_all("SELECT id, issued FROM session_ids WHERE email = $1", user.email, as: {session: String, issued: Time})

  JSON.build do |json|
    json.array do
      tokens.each do |token|
        json.object do
          json.field "session", token[:session]
          json.field "issued", token[:issued].to_unix
        end
      end
    end
  end
end

post "/api/v1/auth/tokens/register" do |env|
  user = env.get("user").as(User)
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  case env.request.headers["Content-Type"]?
  when "application/x-www-form-urlencoded"
    scopes = env.params.body.select { |k, v| k.match(/^scopes\[\d+\]$/) }.map { |k, v| v }
    callback_url = env.params.body["callbackUrl"]?
    expire = env.params.body["expire"]?.try &.to_i?
  when "application/json"
    scopes = env.params.json["scopes"].as(Array).map { |v| v.as_s }
    callback_url = env.params.json["callbackUrl"]?.try &.as(String)
    expire = env.params.json["expire"]?.try &.as(Int64)
  else
    next error_json(400, "Invalid or missing header 'Content-Type'")
  end

  if callback_url && callback_url.empty?
    callback_url = nil
  end

  if callback_url
    callback_url = URI.parse(callback_url)
  end

  if sid = env.get?("sid").try &.as(String)
    env.response.content_type = "text/html"

    csrf_token = generate_response(sid, {":authorize_token"}, HMAC_KEY, PG_DB, use_nonce: true)
    next templated "authorize_token"
  else
    env.response.content_type = "application/json"

    superset_scopes = env.get("scopes").as(Array(String))

    authorized_scopes = [] of String
    scopes.each do |scope|
      if scopes_include_scope(superset_scopes, scope)
        authorized_scopes << scope
      end
    end

    access_token = generate_token(user.email, authorized_scopes, expire, HMAC_KEY, PG_DB)

    if callback_url
      access_token = URI.encode_www_form(access_token)

      if query = callback_url.query
        query = HTTP::Params.parse(query.not_nil!)
      else
        query = HTTP::Params.new
      end

      query["token"] = access_token
      callback_url.query = query.to_s

      env.redirect callback_url.to_s
    else
      access_token
    end
  end
end

post "/api/v1/auth/tokens/unregister" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  scopes = env.get("scopes").as(Array(String))

  session = env.params.json["session"]?.try &.as(String)
  session ||= env.get("session").as(String)

  # Allow tokens to revoke other tokens with correct scope
  if session == env.get("session").as(String)
    PG_DB.exec("DELETE FROM session_ids * WHERE id = $1", session)
  elsif scopes_include_scope(scopes, "GET:tokens")
    PG_DB.exec("DELETE FROM session_ids * WHERE id = $1", session)
  else
    next error_json(400, "Cannot revoke session #{session}")
  end

  env.response.status_code = 204
end

get "/api/manifest/dash/id/videoplayback" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect "/videoplayback?#{env.params.query}"
end

get "/api/manifest/dash/id/videoplayback/*" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect env.request.path.lchop("/api/manifest/dash/id")
end

get "/api/manifest/dash/id/:id" do |env|
  env.response.headers.add("Access-Control-Allow-Origin", "*")
  env.response.content_type = "application/dash+xml"

  local = env.params.query["local"]?.try &.== "true"
  id = env.params.url["id"]
  region = env.params.query["region"]?

  # Since some implementations create playlists based on resolution regardless of different codecs,
  # we can opt to only add a source to a representation if it has a unique height within that representation
  unique_res = env.params.query["unique_res"]?.try { |q| (q == "true" || q == "1").to_unsafe }

  begin
    video = get_video(id, PG_DB, region: region)
  rescue ex : VideoRedirect
    next env.redirect env.request.resource.gsub(id, ex.video_id)
  rescue ex
    env.response.status_code = 403
    next
  end

  if dashmpd = video.dash_manifest_url
    manifest = YT_POOL.client &.get(URI.parse(dashmpd).request_target).body

    manifest = manifest.gsub(/<BaseURL>[^<]+<\/BaseURL>/) do |baseurl|
      url = baseurl.lchop("<BaseURL>")
      url = url.rchop("</BaseURL>")

      if local
        uri = URI.parse(url)
        url = "#{uri.request_target}host/#{uri.host}/"
      end

      "<BaseURL>#{url}</BaseURL>"
    end

    next manifest
  end

  adaptive_fmts = video.adaptive_fmts

  if local
    adaptive_fmts.each do |fmt|
      fmt["url"] = JSON::Any.new(URI.parse(fmt["url"].as_s).request_target)
    end
  end

  audio_streams = video.audio_streams
  video_streams = video.video_streams.sort_by { |stream| {stream["width"].as_i, stream["fps"].as_i} }.reverse

  XML.build(indent: "  ", encoding: "UTF-8") do |xml|
    xml.element("MPD", "xmlns": "urn:mpeg:dash:schema:mpd:2011",
      "profiles": "urn:mpeg:dash:profile:full:2011", minBufferTime: "PT1.5S", type: "static",
      mediaPresentationDuration: "PT#{video.length_seconds}S") do
      xml.element("Period") do
        i = 0

        {"audio/mp4", "audio/webm"}.each do |mime_type|
          mime_streams = audio_streams.select { |stream| stream["mimeType"].as_s.starts_with? mime_type }
          next if mime_streams.empty?

          xml.element("AdaptationSet", id: i, mimeType: mime_type, startWithSAP: 1, subsegmentAlignment: true) do
            mime_streams.each do |fmt|
              codecs = fmt["mimeType"].as_s.split("codecs=")[1].strip('"')
              bandwidth = fmt["bitrate"].as_i
              itag = fmt["itag"].as_i
              url = fmt["url"].as_s

              xml.element("Representation", id: fmt["itag"], codecs: codecs, bandwidth: bandwidth) do
                xml.element("AudioChannelConfiguration", schemeIdUri: "urn:mpeg:dash:23003:3:audio_channel_configuration:2011",
                  value: "2")
                xml.element("BaseURL") { xml.text url }
                xml.element("SegmentBase", indexRange: "#{fmt["indexRange"]["start"]}-#{fmt["indexRange"]["end"]}") do
                  xml.element("Initialization", range: "#{fmt["initRange"]["start"]}-#{fmt["initRange"]["end"]}")
                end
              end
            end
          end

          i += 1
        end

        potential_heights = {4320, 2160, 1440, 1080, 720, 480, 360, 240, 144}

        {"video/mp4", "video/webm"}.each do |mime_type|
          mime_streams = video_streams.select { |stream| stream["mimeType"].as_s.starts_with? mime_type }
          next if mime_streams.empty?

          heights = [] of Int32
          xml.element("AdaptationSet", id: i, mimeType: mime_type, startWithSAP: 1, subsegmentAlignment: true, scanType: "progressive") do
            mime_streams.each do |fmt|
              codecs = fmt["mimeType"].as_s.split("codecs=")[1].strip('"')
              bandwidth = fmt["bitrate"].as_i
              itag = fmt["itag"].as_i
              url = fmt["url"].as_s
              width = fmt["width"].as_i
              height = fmt["height"].as_i

              # Resolutions reported by YouTube player (may not accurately reflect source)
              height = potential_heights.min_by { |i| (height - i).abs }
              next if unique_res && heights.includes? height
              heights << height

              xml.element("Representation", id: itag, codecs: codecs, width: width, height: height,
                startWithSAP: "1", maxPlayoutRate: "1",
                bandwidth: bandwidth, frameRate: fmt["fps"]) do
                xml.element("BaseURL") { xml.text url }
                xml.element("SegmentBase", indexRange: "#{fmt["indexRange"]["start"]}-#{fmt["indexRange"]["end"]}") do
                  xml.element("Initialization", range: "#{fmt["initRange"]["start"]}-#{fmt["initRange"]["end"]}")
                end
              end
            end
          end

          i += 1
        end
      end
    end
  end
end

get "/api/manifest/hls_variant/*" do |env|
  response = YT_POOL.client &.get(env.request.path)

  if response.status_code != 200
    env.response.status_code = response.status_code
    next
  end

  local = env.params.query["local"]?.try &.== "true"

  env.response.content_type = "application/x-mpegURL"
  env.response.headers.add("Access-Control-Allow-Origin", "*")

  manifest = response.body

  if local
    manifest = manifest.gsub("https://www.youtube.com", HOST_URL)
    manifest = manifest.gsub("index.m3u8", "index.m3u8?local=true")
  end

  manifest
end

get "/api/manifest/hls_playlist/*" do |env|
  response = YT_POOL.client &.get(env.request.path)

  if response.status_code != 200
    env.response.status_code = response.status_code
    next
  end

  local = env.params.query["local"]?.try &.== "true"

  env.response.content_type = "application/x-mpegURL"
  env.response.headers.add("Access-Control-Allow-Origin", "*")

  manifest = response.body

  if local
    manifest = manifest.gsub(/^https:\/\/r\d---.{11}\.c\.youtube\.com[^\n]*/m) do |match|
      path = URI.parse(match).path

      path = path.lchop("/videoplayback/")
      path = path.rchop("/")

      path = path.gsub(/mime\/\w+\/\w+/) do |mimetype|
        mimetype = mimetype.split("/")
        mimetype[0] + "/" + mimetype[1] + "%2F" + mimetype[2]
      end

      path = path.split("/")

      raw_params = {} of String => Array(String)
      path.each_slice(2) do |pair|
        key, value = pair
        value = URI.decode_www_form(value)

        if raw_params[key]?
          raw_params[key] << value
        else
          raw_params[key] = [value]
        end
      end

      raw_params = HTTP::Params.new(raw_params)
      if fvip = raw_params["hls_chunk_host"].match(/r(?<fvip>\d+)---/)
        raw_params["fvip"] = fvip["fvip"]
      end

      raw_params["local"] = "true"

      "#{HOST_URL}/videoplayback?#{raw_params}"
    end
  end

  manifest
end

# YouTube /videoplayback links expire after 6 hours,
# so we have a mechanism here to redirect to the latest version
get "/latest_version" do |env|
  if env.params.query["download_widget"]?
    download_widget = JSON.parse(env.params.query["download_widget"])

    id = download_widget["id"].as_s
    title = download_widget["title"].as_s

    if label = download_widget["label"]?
      env.redirect "/api/v1/captions/#{id}?label=#{label}&title=#{title}"
      next
    else
      itag = download_widget["itag"].as_s.to_i
      local = "true"
    end
  end

  id ||= env.params.query["id"]?
  itag ||= env.params.query["itag"]?.try &.to_i

  region = env.params.query["region"]?

  local ||= env.params.query["local"]?
  local ||= "false"
  local = local == "true"

  if !id || !itag
    env.response.status_code = 400
    next
  end

  video = get_video(id, PG_DB, region: region)

  fmt = video.fmt_stream.find(nil) { |f| f["itag"].as_i == itag } || video.adaptive_fmts.find(nil) { |f| f["itag"].as_i == itag }
  url = fmt.try &.["url"]?.try &.as_s

  if !url
    env.response.status_code = 404
    next
  end

  url = URI.parse(url).request_target.not_nil! if local
  url = "#{url}&title=#{title}" if title

  env.redirect url
end

options "/videoplayback" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/videoplayback/*" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/api/manifest/dash/id/videoplayback" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

options "/api/manifest/dash/id/videoplayback/*" do |env|
  env.response.headers.delete("Content-Type")
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

get "/videoplayback/*" do |env|
  path = env.request.path

  path = path.lchop("/videoplayback/")
  path = path.rchop("/")

  path = path.gsub(/mime\/\w+\/\w+/) do |mimetype|
    mimetype = mimetype.split("/")
    mimetype[0] + "/" + mimetype[1] + "%2F" + mimetype[2]
  end

  path = path.split("/")

  raw_params = {} of String => Array(String)
  path.each_slice(2) do |pair|
    key, value = pair
    value = URI.decode_www_form(value)

    if raw_params[key]?
      raw_params[key] << value
    else
      raw_params[key] = [value]
    end
  end

  query_params = HTTP::Params.new(raw_params)

  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.redirect "/videoplayback?#{query_params}"
end

get "/videoplayback" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  query_params = env.params.query

  fvip = query_params["fvip"]? || "3"
  mns = query_params["mn"]?.try &.split(",")
  mns ||= [] of String

  if query_params["region"]?
    region = query_params["region"]
    query_params.delete("region")
  end

  if query_params["host"]? && !query_params["host"].empty?
    host = "https://#{query_params["host"]}"
    query_params.delete("host")
  else
    host = "https://r#{fvip}---#{mns.pop}.googlevideo.com"
  end

  url = "/videoplayback?#{query_params.to_s}"

  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  client = make_client(URI.parse(host), region)
  response = HTTP::Client::Response.new(500)
  error = ""
  5.times do
    begin
      response = client.head(url, headers)

      if response.headers["Location"]?
        location = URI.parse(response.headers["Location"])
        env.response.headers["Access-Control-Allow-Origin"] = "*"

        new_host = "#{location.scheme}://#{location.host}"
        if new_host != host
          host = new_host
          client.close
          client = make_client(URI.parse(new_host), region)
        end

        url = "#{location.request_target}&host=#{location.host}#{region ? "&region=#{region}" : ""}"
      else
        break
      end
    rescue Socket::Addrinfo::Error
      if !mns.empty?
        mn = mns.pop
      end
      fvip = "3"

      host = "https://r#{fvip}---#{mn}.googlevideo.com"
      client = make_client(URI.parse(host), region)
    rescue ex
      error = ex.message
    end
  end

  if response.status_code >= 400
    env.response.status_code = response.status_code
    env.response.content_type = "text/plain"
    next error
  end

  if url.includes? "&file=seg.ts"
    if CONFIG.disabled?("livestreams")
      next error_template(403, "Administrator has disabled this endpoint.")
    end

    begin
      client.get(url, headers) do |response|
        response.headers.each do |key, value|
          if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
            env.response.headers[key] = value
          end
        end

        env.response.headers["Access-Control-Allow-Origin"] = "*"

        if location = response.headers["Location"]?
          location = URI.parse(location)
          location = "#{location.request_target}&host=#{location.host}"

          if region
            location += "&region=#{region}"
          end

          next env.redirect location
        end

        IO.copy(response.body_io, env.response)
      end
    rescue ex
    end
  else
    if query_params["title"]? && CONFIG.disabled?("downloads") ||
       CONFIG.disabled?("dash")
      next error_template(403, "Administrator has disabled this endpoint.")
    end

    content_length = nil
    first_chunk = true
    range_start, range_end = parse_range(env.request.headers["Range"]?)
    chunk_start = range_start
    chunk_end = range_end

    if !chunk_end || chunk_end - chunk_start > HTTP_CHUNK_SIZE
      chunk_end = chunk_start + HTTP_CHUNK_SIZE - 1
    end

    # TODO: Record bytes written so we can restart after a chunk fails
    while true
      if !range_end && content_length
        range_end = content_length
      end

      if range_end && chunk_start > range_end
        break
      end

      if range_end && chunk_end > range_end
        chunk_end = range_end
      end

      headers["Range"] = "bytes=#{chunk_start}-#{chunk_end}"

      begin
        client.get(url, headers) do |response|
          if first_chunk
            if !env.request.headers["Range"]? && response.status_code == 206
              env.response.status_code = 200
            else
              env.response.status_code = response.status_code
            end

            response.headers.each do |key, value|
              if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase) && key.downcase != "content-range"
                env.response.headers[key] = value
              end
            end

            env.response.headers["Access-Control-Allow-Origin"] = "*"

            if location = response.headers["Location"]?
              location = URI.parse(location)
              location = "#{location.request_target}&host=#{location.host}#{region ? "&region=#{region}" : ""}"

              env.redirect location
              break
            end

            if title = query_params["title"]?
              # https://blog.fastmail.com/2011/06/24/download-non-english-filenames/
              env.response.headers["Content-Disposition"] = "attachment; filename=\"#{URI.encode_www_form(title)}\"; filename*=UTF-8''#{URI.encode_www_form(title)}"
            end

            if !response.headers.includes_word?("Transfer-Encoding", "chunked")
              content_length = response.headers["Content-Range"].split("/")[-1].to_i64
              if env.request.headers["Range"]?
                env.response.headers["Content-Range"] = "bytes #{range_start}-#{range_end || (content_length - 1)}/#{content_length}"
                env.response.content_length = ((range_end.try &.+ 1) || content_length) - range_start
              else
                env.response.content_length = content_length
              end
            end
          end

          proxy_file(response, env)
        end
      rescue ex
        if ex.message != "Error reading socket: Connection reset by peer"
          break
        else
          client.close
          client = make_client(URI.parse(host), region)
        end
      end

      chunk_start = chunk_end + 1
      chunk_end += HTTP_CHUNK_SIZE
      first_chunk = false
    end
  end
  client.close
end

get "/ggpht/*" do |env|
  url = env.request.path.lchop("/ggpht")

  headers = HTTP::Headers{":authority" => "yt3.ggpht.com"}
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

options "/sb/:authority/:id/:storyboard/:index" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

get "/sb/:authority/:id/:storyboard/:index" do |env|
  authority = env.params.url["authority"]
  id = env.params.url["id"]
  storyboard = env.params.url["storyboard"]
  index = env.params.url["index"]

  url = "/sb/#{id}/#{storyboard}/#{index}?#{env.params.query}"

  headers = HTTP::Headers.new

  headers[":authority"] = "#{authority}.ytimg.com"

  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Connection"] = "close"
      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/s_p/:id/:name" do |env|
  id = env.params.url["id"]
  name = env.params.url["name"]

  url = env.request.resource

  headers = HTTP::Headers{":authority" => "i9.ytimg.com"}
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/yts/img/:name" do |env|
  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(env.request.resource, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/vi/:id/:name" do |env|
  id = env.params.url["id"]
  name = env.params.url["name"]

  headers = HTTP::Headers{":authority" => "i.ytimg.com"}

  if name == "maxres.jpg"
    build_thumbnails(id).each do |thumb|
      if YT_POOL.client &.head("/vi/#{id}/#{thumb[:url]}.jpg", headers).status_code == 200
        name = thumb[:url] + ".jpg"
        break
      end
    end
  end
  url = "/vi/#{id}/#{name}"

  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/Captcha" do |env|
  headers = HTTP::Headers{":authority" => "accounts.google.com"}
  response = YT_POOL.client &.get(env.request.resource, headers)
  env.response.headers["Content-Type"] = response.headers["Content-Type"]
  response.body
end

# Undocumented, creates anonymous playlist with specified 'video_ids', max 50 videos
get "/watch_videos" do |env|
  response = YT_POOL.client &.get(env.request.resource)
  if url = response.headers["Location"]?
    url = URI.parse(url).request_target
    next env.redirect url
  end

  env.response.status_code = response.status_code
end

error 404 do |env|
  if md = env.request.path.match(/^\/(?<id>([a-zA-Z0-9_-]{11})|(\w+))$/)
    item = md["id"]

    # Check if item is branding URL e.g. https://youtube.com/gaming
    response = YT_POOL.client &.get("/#{item}")

    if response.status_code == 301
      response = YT_POOL.client &.get(URI.parse(response.headers["Location"]).request_target)
    end

    if response.body.empty?
      env.response.headers["Location"] = "/"
      halt env, status_code: 302
    end

    html = XML.parse_html(response.body)
    ucid = html.xpath_node(%q(//link[@rel="canonical"])).try &.["href"].split("/")[-1]

    if ucid
      env.response.headers["Location"] = "/channel/#{ucid}"
      halt env, status_code: 302
    end

    params = [] of String
    env.params.query.each do |k, v|
      params << "#{k}=#{v}"
    end
    params = params.join("&")

    url = "/watch?v=#{item}"
    if !params.empty?
      url += "&#{params}"
    end

    # Check if item is video ID
    if item.match(/^[a-zA-Z0-9_-]{11}$/) && YT_POOL.client &.head("/watch?v=#{item}").status_code != 404
      env.response.headers["Location"] = url
      halt env, status_code: 302
    end
  end

  env.response.headers["Location"] = "/"
  halt env, status_code: 302
end

error 500 do |env, ex|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  error_template(500, ex)
end

static_headers do |response, filepath, filestat|
  response.headers.add("Cache-Control", "max-age=2629800")
end

public_folder "assets"

Kemal.config.powered_by_header = false
add_handler FilteredCompressHandler.new
add_handler APIHandler.new
add_handler AuthHandler.new
add_handler DenyFrame.new
add_context_storage_type(Array(String))
add_context_storage_type(Preferences)
add_context_storage_type(User)

Kemal.config.logger = LOGGER
Kemal.config.host_binding = Kemal.config.host_binding != "0.0.0.0" ? Kemal.config.host_binding : CONFIG.host_binding
Kemal.config.port = Kemal.config.port != 3000 ? Kemal.config.port : CONFIG.port
Kemal.run
