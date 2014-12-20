module OpenGraphReader
  # Convert a {Parser::Graph} into the right hierarchy of {Object}s attached
  # to a {Base}, then validate it.
  #
  # @api private
  class Builder
    # Well-known types from
    #
    # @see http://ogp.me
    KNOWN_TYPES = %w(website article book profile).freeze

    # Create a new builder.
    #
    # @param [Parser] parser
    # @see Parser#graph
    # @see Parser#additional_namespaces
    def initialize parser
      @parser = parser
    end

    # Build and return the base.
    #
    # @return [Base]
    def base
      base = Base.new

      type = @parser.graph.fetch('og:type', 'website').downcase

      validate_type type

      @parser.graph.each do |property|
        build_property base, property
      end

      synthesize_required_properties base
      drop_empty_children base
      validate base

      base
    end

    private

    def build_property base, property
      root, *path, name = property.path
      base[root] ||= Object::Registry[root].new
      object = resolve base[root], root, path

      if object.has_property?(name) && object.respond_to?("#{name}s") # Collection
        collection = object.public_send "#{name}s"
        if Object::Registry.registered? property.fullname # of subobjects
          object = Object::Registry[property.fullname].new
          collection << object
          object.content = property.content
        else # of type
          collection << property.content
        end
      elsif Object::Registry.registered? property.fullname # Subobject
        object[name] ||= Object::Registry[property.fullname].new
        object[name].content = property.content
      else # Direct attribute
        object[name] = property.content
      end
    rescue UnknownNamespaceError, UndefinedPropertyError => e
      raise InvalidObjectError, e.message if OpenGraphReader.config.strict
    end

    def resolve object, last_namespace, path
      return object if path.empty?

      next_name = path.shift
      if object.has_property?(next_name) && object.respond_to?("#{next_name}s") # collection
        collection = object.public_send("#{next_name}s")
        next_object = collection.last
        if next_object.nil? # Final namespace or missing previous declaration, create a new collection item
          next_object = Object::Registry[[*last_namespace, next_name].join(':')].new
          collection << next_object
        end
      else
        next_object = object[next_name]
        next_object ||= Object::Registry[[*last_namespace, next_name].join(':')].new
      end

      next_object
    end

    def synthesize_required_properties base
      if OpenGraphReader.config.synthesize_title && base.og.title.nil?
        base.og['title'] = @parser.title
      end
    end

    def drop_empty_children base
      base = base.children
      base.each do |key, object|
        [*object].each do |object|
          if object.is_a? Object
            drop_empty_children object
            base.delete(key) if object.content.nil? && object.children.empty? && object.properties.empty?
          end
        end
      end
    end

    def validate_type type
      return unless OpenGraphReader.config.strict

      unless KNOWN_TYPES.include?(type) ||
             @parser.additional_namespaces.include?(type) ||
             Object::Registry.verticals.include?(type)
        raise InvalidObjectError, "Undefined type #{type}"
      end
    end

    def validate base
      base.each do |object|
        validate_required object if OpenGraphReader.config.validate_required
        validate_verticals object, base.og.type
      end
    end

    def validate_required object
      object.class.required_properties.each do |property|
        if object[property].nil?
          raise InvalidObjectError, "Missing required property #{property} on #{object.inspect}"
        end
      end
    end

    def validate_verticals object, type
      return unless type.include? '.'
      verticals = object.class.verticals
      if verticals.has_key? type
        valid_properties = verticals[type]
        set_properties = object.class.available_properties.select {|property| object[property] }
        extra_properties = set_properties-valid_properties

        unless extra_properties.empty?
          raise InvalidObjectError, "Set invalid property #{extra_properties.first} for #{type} " \
            "in #{object.inspect}, valid properties are #{valid_properties.inspect}"
        end
      end
    end
  end
end
