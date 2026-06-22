require 'kramdown'
require 'haml'

class SVG_Icons
	ICONS = {
		linkedin:      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="14" height="14" fill="currentColor" stroke="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 8a6 6 0 0 1 6 6v7h-4v-7a2 2 0 0 0-2-2 2 2 0 0 0-2 2v7h-4v-7a6 6 0 0 1 6-6z"/><rect x="2" y="9" width="4" height="12"/><circle cx="4" cy="4" r="2"/></svg>',
		external_link: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>',
		book:          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg>',
		email:         '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/></svg>',
		arrow_right:   '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/></svg>',
		arrow_down:    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><polyline points="19 12 12 19 5 12"/></svg>',
		scroll_down:   '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><polyline points="6 9 12 15 18 9"/></svg>',
		success_check: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>',
	}
end

def make_slug(text)
    text.to_s.unicode_normalize(:nfkd)
        .encode('ASCII', invalid: :replace, undef: :replace, replace: '')
        .downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
end

# Read the pixel dimensions of an image under content/ (PNG, JPEG, WebP).
# Returns { width:, height: } or {} if the file is missing/unreadable, so
# callers can merge the result into attribute hashes safely.
def image_dimensions(path)
    @image_dimensions_cache ||= {}
    return @image_dimensions_cache[path] if @image_dimensions_cache.key?(path)

    @image_dimensions_cache[path] = begin
        file = File.join('content', path.to_s)
        if File.file?(file)
            bytes = File.binread(file, 64)
            if bytes[0, 8] == "\x89PNG\r\n\x1a\n".b
                w, h = bytes[16, 8].unpack('N2')
                { width: w, height: h }
            elsif bytes[0, 2] == "\xFF\xD8".b
                jpeg_dimensions(file)
            elsif bytes[0, 4] == 'RIFF' && bytes[8, 4] == 'WEBP'
                webp_dimensions(bytes)
            else
                {}
            end
        else
            {}
        end
    rescue StandardError
        {}
    end
end

private

def jpeg_dimensions(file)
    File.open(file, 'rb') do |io|
        io.seek(2)
        while (marker = io.read(2))
            return {} unless marker.getbyte(0) == 0xFF
            type = marker.getbyte(1)
            next if type == 0xFF # padding
            break if type == 0xD9 # EOI
            len = io.read(2).unpack1('n')
            if (0xC0..0xCF).cover?(type) && ![0xC4, 0xC8, 0xCC].include?(type)
                data = io.read(5)
                h, w = data[1, 4].unpack('n2')
                return { width: w, height: h }
            end
            io.seek(len - 2, IO::SEEK_CUR)
        end
    end
    {}
end

def webp_dimensions(bytes)
    case bytes[12, 4]
    when 'VP8X'
        w = (bytes[24].ord | (bytes[25].ord << 8) | (bytes[26].ord << 16)) + 1
        h = (bytes[27].ord | (bytes[28].ord << 8) | (bytes[29].ord << 16)) + 1
        { width: w, height: h }
    when 'VP8 '
        return {} unless bytes[23, 3] == "\x9D\x01\x2A".b
        w, h = bytes[26, 4].unpack('v2')
        { width: w & 0x3FFF, height: h & 0x3FFF }
    when 'VP8L'
        return {} unless bytes[20].ord == 0x2F
        b = bytes[21, 4].unpack1('V')
        { width: (b & 0x3FFF) + 1, height: ((b >> 14) & 0x3FFF) + 1 }
    else
        {}
    end
end

public

# Attribute hash for content images: src, alt, intrinsic dimensions (CLS),
# async decoding and lazy loading. Pass eager: true for above-the-fold
# images (heroes); extra attributes are merged on top.
def image_attrs(src, alt, eager: false, **extra)
    attrs = { src: src, alt: alt }.merge(image_dimensions(src))
    attrs[:loading] = 'lazy' unless eager
    attrs[:decoding] = 'async'
    attrs.merge(extra)
end

# Return the path to a video's caption track (VTT) if one exists under
# content/videos/transcripts/, for use as a <track> src. Returns nil if
# no transcript has been generated for this video.
def video_transcript_path(path)
    name = File.basename(path.to_s, '.*')
    transcript = "/videos/transcripts/#{name}.vtt"
    File.file?(File.join('content', transcript)) ? transcript : nil
end

def make_haml(haml_string, locals = {})
    Haml::Template.new(escape_html: false) { haml_string }.render(Object.new, locals)
end

def markdown_to_html(blob)
    Kramdown::Document.new(blob).to_html
end

def excerpt_from_markdown(markdown, max_length)
    plain_text = markdown_to_html(markdown).gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
    return plain_text if plain_text.length <= max_length

    plain_text[0...max_length].sub(/\s+\S*\z/, '') + '…'
end

def date_parse(datetime)
    DateTime.parse(datetime.to_s)
end

def svg_icon(name)
  SVG_Icons::ICONS[name] || ''
end
