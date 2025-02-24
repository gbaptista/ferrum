# frozen_string_literal: true

require "ferrum/rbga"

module Ferrum
  class Page
    module Screenshot
      DEFAULT_PDF_OPTIONS = {
        landscape: false,
        paper_width: 8.5,
        paper_height: 11,
        scale: 1.0
      }.freeze

      PAPER_FORMATS = {
        letter: { width: 8.50, height: 11.00 },
        legal: { width: 8.50, height: 14.00 },
        tabloid: { width: 11.00, height: 17.00 },
        ledger: { width: 17.00, height: 11.00 },
        A0: { width: 33.10, height: 46.80 },
        A1: { width: 23.40, height: 33.10 },
        A2: { width: 16.54, height: 23.40 },
        A3: { width: 11.70, height: 16.54 },
        A4: { width:  8.27, height: 11.70 },
        A5: { width:  5.83, height:  8.27 },
        A6: { width:  4.13, height:  5.83 }
      }.freeze

      STREAM_CHUNK = 128 * 1024

      def screenshot(**opts)
        path, encoding = common_options(**opts)
        options = screenshot_options(path, **opts)
        data = capture_screenshot(options, opts[:full], opts[:background_color])
        return data if encoding == :base64

        bin = Base64.decode64(data)
        save_file(path, bin)
      end

      def pdf(**opts)
        path, encoding = common_options(**opts)
        options = pdf_options(**opts).merge(transferMode: "ReturnAsStream")
        handle = command("Page.printToPDF", **options).fetch("stream")

        if path
          stream_to_file(handle, path: path)
        else
          stream_to_memory(handle, encoding: encoding)
        end
      end

      def mhtml(path: nil)
        data = command("Page.captureSnapshot", format: :mhtml).fetch("data")
        return data if path.nil?

        save_file(path, data)
      end

      def viewport_size
        evaluate <<~JS
          [window.innerWidth, window.innerHeight]
        JS
      end

      def document_size
        evaluate <<~JS
          [document.documentElement.scrollWidth,
           document.documentElement.scrollHeight]
        JS
      end

      private

      def save_file(path, data)
        return data unless path

        File.binwrite(path.to_s, data)
      end

      def stream_to_file(handle, path:)
        File.open(path, "wb") { |f| stream_to(handle, f) }
        true
      end

      def stream_to_memory(handle, encoding:)
        data = String.new("") # Mutable string has << and compatible to File
        stream_to(handle, data)
        encoding == :base64 ? Base64.encode64(data) : data
      end

      def stream_to(handle, output)
        loop do
          result = command("IO.read", handle: handle, size: STREAM_CHUNK)

          data_chunk = result["data"]
          data_chunk = Base64.decode64(data_chunk) if result["base64Encoded"]
          output << data_chunk

          break if result["eof"]
        end
      end

      def common_options(encoding: :base64, path: nil, **_)
        encoding = encoding.to_sym
        encoding = :binary if path
        [path, encoding]
      end

      def pdf_options(**opts)
        format = opts.delete(:format)
        options = DEFAULT_PDF_OPTIONS.merge(opts)

        if format
          if opts[:paper_width] || opts[:paper_height]
            raise ArgumentError, "Specify :format or :paper_width, :paper_height"
          end

          dimension = PAPER_FORMATS.fetch(format)
          options.merge!(paper_width: dimension[:width],
                         paper_height: dimension[:height])
        end

        options.transform_keys { |k| to_camel_case(k) }
      end

      def screenshot_options(path = nil, format: nil, scale: 1.0, **options)
        screenshot_options = {}

        format, quality = format_options(format, path, options[:quality])
        screenshot_options.merge!(quality: quality) if quality
        screenshot_options.merge!(format: format)

        clip = area_options(options[:full], options[:selector], scale)
        screenshot_options.merge!(clip: clip) if clip

        screenshot_options
      end

      def format_options(format, path, quality)
        format ||= path ? File.extname(path).delete(".") : "png"
        format = "jpeg" if format == "jpg"
        raise "Not supported options `:format` #{format}. jpeg | png" if format !~ /jpeg|png/i

        quality ||= 75 if format == "jpeg"

        [format, quality]
      end

      def area_options(full, selector, scale)
        message = "Ignoring :selector in #screenshot since full: true was given at #{caller(1..1).first}"
        warn(message) if full && selector

        clip = if full
                 width, height = document_size
                 { x: 0, y: 0, width: width, height: height, scale: scale } if width.positive? && height.positive?
               elsif selector
                 bounding_rect(selector).merge(scale: scale)
               end

        if scale != 1
          unless clip
            width, height = viewport_size
            clip = { x: 0, y: 0, width: width, height: height }
          end

          clip.merge!(scale: scale)
        end

        clip
      end

      def bounding_rect(selector)
        rect = evaluate_async(%(
          const rect = document
                         .querySelector('#{selector}')
                         .getBoundingClientRect();
          const {x, y, width, height} = rect;
          arguments[0]([x, y, width, height])
        ), timeout)

        { x: rect[0], y: rect[1], width: rect[2], height: rect[3] }
      end

      def to_camel_case(option)
        return :preferCSSPageSize if option == :prefer_css_page_size

        option.to_s.gsub(%r{(?:_|(/))([a-z\d]*)}) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).capitalize}" }.to_sym
      end

      def capture_screenshot(options, full, background_color)
        maybe_resize_fullscreen(full) do
          with_background_color(background_color) do
            command("Page.captureScreenshot", **options)
          end
        end.fetch("data")
      end

      def maybe_resize_fullscreen(full)
        if full
          width, height = viewport_size.dup
          resize(fullscreen: true)
        end

        yield
      ensure
        resize(width: width, height: height) if full
      end

      def with_background_color(color)
        if color
          raise ArgumentError, "Accept Ferrum::RGBA class only" unless color.is_a?(RGBA)

          command("Emulation.setDefaultBackgroundColorOverride", color: color.to_h)
        end

        yield
      ensure
        command("Emulation.setDefaultBackgroundColorOverride") if color
      end
    end
  end
end
