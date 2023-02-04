require "json"

module Invidious::JSONify::APIv1
  extend self

  def video(video : Video, json : JSON::Builder, *, locale : String?, proxy : Bool = false)
    json.object do
      json.field "type", video.video_type

      json.field "title", video.title
      json.field "videoId", video.id

      json.field "error", video.info["reason"] if video.info["reason"]?

      json.field "videoThumbnails" do
        self.thumbnails(json, video.id)
      end
      json.field "storyboards" do
        self.storyboards(json, video.id, video.storyboards)
      end

      json.field "description", video.description
      json.field "descriptionHtml", video.description_html
      json.field "published", video.published.to_unix
      json.field "publishedText", translate(locale, "`x` ago", recode_date(video.published, locale))
      json.field "keywords", video.keywords

      json.field "viewCount", video.views
      json.field "likeCount", video.likes
      json.field "dislikeCount", 0_i64

      json.field "paid", video.paid
      json.field "premium", video.premium
      json.field "isFamilyFriendly", video.is_family_friendly
      json.field "allowedRegions", video.allowed_regions
      json.field "genre", video.genre
      json.field "genreUrl", video.genre_url

      json.field "author", video.author
      json.field "authorId", video.ucid
      json.field "authorUrl", "/channel/#{video.ucid}"
      json.field "authorVerified", video.author_verified

      json.field "authorThumbnails" do
        json.array do
          qualities = {32, 48, 76, 100, 176, 512}

          qualities.each do |quality|
            json.object do
              json.field "url", video.author_thumbnail.gsub(/=s\d+/, "=s#{quality}")
              json.field "width", quality
              json.field "height", quality
            end
          end
        end
      end

      json.field "subCountText", video.sub_count_text

      json.field "lengthSeconds", video.length_seconds
      json.field "allowRatings", video.allow_ratings
      json.field "rating", 0_i64
      json.field "isListed", video.is_listed
      json.field "liveNow", video.live_now
      json.field "isUpcoming", video.is_upcoming

      if video.premiere_timestamp
        json.field "premiereTimestamp", video.premiere_timestamp.try &.to_unix
      end

      if hlsvp = video.hls_manifest_url
        hlsvp = hlsvp.gsub("https://manifest.googlevideo.com", HOST_URL)
        json.field "hlsUrl", hlsvp
      end

      json.field "dashUrl", "#{HOST_URL}/api/manifest/dash/id/#{video.id}"

      json.field "adaptiveFormats" do
        json.array do
          video.adaptive_fmts.each do |fmt|
            json.object do
              # Only available on regular videos, not livestreams/OTF streams
              json.field "init", fmt.init_range.to_s if fmt.init_range
              json.field "index", fmt.index_range.to_s if fmt.index_range

              # Livestream chunk infos. Should be present when `init` and `index` aren't
              json.field "targetDurationSec", fmt.target_duration if fmt.target_duration
              json.field "maxDvrDurationSec", fmt.max_dvr_duration if fmt.max_dvr_duration

              # Not available on MPEG-4 Timed Text (`text/mp4`) streams (livestreams only)
              json.field "bitrate", fmt.bitrate.to_s if fmt.responds_to?(:bitrate)

              if proxy
                json.field "url", Invidious::HttpServer::Utils.proxy_video_url(
                  fmt.url, absolute: true
                )
              else
                json.field "url", fmt.url
              end

              json.field "itag", fmt.itag.to_s
              json.field "type", fmt.raw_mime_type
              json.field "clen", fmt.content_length if fmt.responds_to?(:content_length)

              json.field "encoding", fmt.codecs

              # Last modified is a unix timestamp with µS, with the dot omitted.
              # E.g: 1638056732(.)141582
              #
              # On livestreams, it's not present, so always fall back to the
              # current unix timestamp (up to mS precision) for compatibility.
              last_modified = fmt.last_modified || Time.utc
              json.field "lmt", "#{last_modified.to_unix_ms}000"

              json.field "projectionType", fmt.projection_type.to_s.upcase

              if fmt.is_a?(Videos::AdaptativeVideoStream)
                json.field "fps", fmt.video_fps
                json.field "size", "#{fmt.video_width}x#{fmt.video_height}"
              end

              if fmt_info = Invidious::Videos::Formats.itag_to_metadata?(fmt.itag)
                json.field "container", fmt_info["ext"]

                if fmt_info["height"]?
                  json.field "resolution", "#{fmt_info["height"]}p"

                  quality_label = "#{fmt_info["height"]}p"
                  quality_label += "60" if fmt.responds_to?(:video_fps) && fmt.video_fps > 30
                  json.field "qualityLabel", quality_label
                end
              end

              # Audio-related data
              if fmt.is_a?(Videos::AdaptativeAudioStream)
                json.field "audioQuality", fmt.audio_quality
                json.field "audioSampleRate", fmt.audio_sample_rate
                json.field "audioChannels", fmt.audio_channels
              end

              # Extra misc stuff
              # json.field "colorInfo", fmt["colorInfo"] if fmt.has_key?("colorInfo")
              # json.field "captionTrack", fmt["captionTrack"] if fmt.has_key?("captionTrack")
            end
          end
        end
      end

      json.field "formatStreams" do
        json.array do
          video.fmt_stream.each do |fmt|
            json.object do
              json.field "url", fmt.url
              json.field "itag", fmt.itag.to_s
              json.field "type", fmt.raw_mime_type
              json.field "quality", fmt.label

              json.field "encoding", fmt.codecs

              json.field "size", "#{fmt.video_width}x#{fmt.video_height}"
              json.field "fps", fmt.video_fps

              if fmt_info = Invidious::Videos::Formats.itag_to_metadata?(fmt.itag)
                json.field "container", fmt_info["ext"]

                if fmt_info["height"]?
                  json.field "resolution", "#{fmt_info["height"]}p"

                  quality_label = "#{fmt_info["height"]}p"
                  quality_label += "60" if fmt.video_fps > 30
                  json.field "qualityLabel", quality_label
                end
              end
            end
          end
        end
      end

      json.field "captions" do
        json.array do
          video.captions.each do |caption|
            json.object do
              json.field "label", caption.name
              json.field "language_code", caption.language_code
              json.field "url", "/api/v1/captions/#{video.id}?label=#{URI.encode_www_form(caption.name)}"
            end
          end
        end
      end

      if !video.music.empty?
        json.field "musicTracks" do
          json.array do
            video.music.each do |music|
              json.object do
                json.field "song", music.song
                json.field "artist", music.artist
                json.field "album", music.album
                json.field "license", music.license
              end
            end
          end
        end
      end

      json.field "recommendedVideos" do
        json.array do
          video.related_videos.each do |rv|
            if rv["id"]?
              json.object do
                json.field "videoId", rv["id"]
                json.field "title", rv["title"]
                json.field "videoThumbnails" do
                  self.thumbnails(json, rv["id"])
                end

                json.field "author", rv["author"]
                json.field "authorUrl", "/channel/#{rv["ucid"]?}"
                json.field "authorId", rv["ucid"]?
                if rv["author_thumbnail"]?
                  json.field "authorThumbnails" do
                    json.array do
                      qualities = {32, 48, 76, 100, 176, 512}

                      qualities.each do |quality|
                        json.object do
                          json.field "url", rv["author_thumbnail"].gsub(/s\d+-/, "s#{quality}-")
                          json.field "width", quality
                          json.field "height", quality
                        end
                      end
                    end
                  end
                end

                json.field "lengthSeconds", rv["length_seconds"]?.try &.to_i
                json.field "viewCountText", rv["short_view_count"]?
                json.field "viewCount", rv["view_count"]?.try &.empty? ? nil : rv["view_count"].to_i64
              end
            end
          end
        end
      end
    end
  end

  def storyboards(json, id, storyboards)
    json.array do
      storyboards.each do |storyboard|
        json.object do
          json.field "url", "/api/v1/storyboards/#{id}?width=#{storyboard[:width]}&height=#{storyboard[:height]}"
          json.field "templateUrl", storyboard[:url]
          json.field "width", storyboard[:width]
          json.field "height", storyboard[:height]
          json.field "count", storyboard[:count]
          json.field "interval", storyboard[:interval]
          json.field "storyboardWidth", storyboard[:storyboard_width]
          json.field "storyboardHeight", storyboard[:storyboard_height]
          json.field "storyboardCount", storyboard[:storyboard_count]
        end
      end
    end
  end
end
