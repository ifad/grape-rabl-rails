module Grape
  module Formatter
    class RablRails

      def initialize(options)
        @view_root = options.fetch(:views).dup.freeze
        self.freeze

      rescue KeyError => e
        raise ConfigurationError, e.message
      end

      def call(block_retval, env)
        format, endpoint = env.values_at *%w(api.format api.endpoint)

        endpoint.instance_variable_set(:@result, block_retval)

        if (template = extract_template(endpoint))
          Library.on_view_root(@view_root) do
            Library.instance.render template, context: endpoint, format: format
          end
        else
          fallback = Grape::Formatter.const_get(format.to_s.capitalize)
          fallback.call(block_retval, env)
        end
      end

      private

      def extract_template(endpoint)
        namespace, template = []

        if (result = endpoint.instance_variable_get(:@result)).respond_to?(:to_partial_path)
          ns, template = result.to_partial_path.split('/')
          namespace    = ::Grape::Namespace.new(ns)
        end

        if ns = endpoint.settings[:namespace]
          namespace = ns
          template  = namespace.options[:rabl] if namespace.options.has_key?(:rabl)
        end

        if (o = endpoint.options[:route_options]).has_key?(:rabl)
          template = o[:rabl]
        end

        return template && [namespace && namespace.space, template.to_s].compact.join('/')
      end

      # Re-implement RablRails Library for now - better solutions have to be
      # envisioned by refactoring RablRails' Library itself and decoupling it
      # from Rails' internals.
      #
      class Library
        # HACK override RablRails' Library for now
        ::RablRails::Library = self

        include Singleton

        def initialize
          @cache = {}
        end

        def render(template, options)
          template = compile(template)
          format   = options.fetch(:format, 'JSON').to_s.upcase
          context  = options.fetch(:context)

          ::RablRails::Renderers.const_get(format).new(context).render(template)
        end

        def compile(template)
          path = _lookup(template)

          if ::RablRails.cache_templates?
            (@cache[path] ||= _compile(path)).dup
          else
            _compile(path)
          end
        end

        # Compatibility for Partial rendering
        alias :compile_template_from_path :compile

        private
        def _compile(path)
          ::RablRails::Compiler.new.compile_source(File.read(path))

        rescue Errno::ENOENT
          raise TemplateNotFound.new(path)
        end

        def _lookup(template)
          template += '.rabl' unless template =~ /\.rabl\Z/
          File.join(Thread.current['grape.rabl.root'], template)
        end

        def self.on_view_root(root)
          # Better this than having race conditions due
          # to instance variables in the Singleton
          Thread.current['grape.rabl.root'] = root
          yield
        ensure
          Thread.current['grape.rabl.root'] = nil
        end
      end

      class ConfigurationError < StandardError
      end

      class TemplateNotFound < StandardError
        def initialize(path)
          @path = path
        end

        def message
          "Template not found: #@path"
        end
      end

    end
  end
end
