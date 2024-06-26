require 'digest/md5'

module SPARQL; class Client
  ##
  # A SPARQL query builder.
  #
  # @example Iterating over all found solutions
  #   query.each_solution { |solution| puts solution.inspect }
  #
  class Query < RDF::Query
    ##
    # @return [Symbol]
    # @see    http://www.w3.org/TR/sparql11-query/#QueryForms
    attr_reader :form

    ##
    # @return [Hash{Symbol => Object}]
    attr_reader :options

    ##
    # @return [Array<[key, RDF::Value]>]
    attr_reader :values

    ##
    # Creates a boolean `ASK` query.
    #
    # @param  [Hash{Symbol => Object}] options
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#ask
    def self.ask(options = {})
      self.new(:ask, options)
    end

    ##
    # Creates a tuple `SELECT` query.
    #
    # @param  [Array<Symbol>]          variables
    # @return [Query]
    #
    # @overload self.select(*variables, options)
    #   @param  [Array<Symbol>]          variables
    #   @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#select
    def self.select(*variables)
      options = variables.last.is_a?(Hash) ? variables.pop : {}
      self.new(:select, options).select(*variables)
    end

    ##
    # Creates a `DESCRIBE` query.
    #
    # @param  [Array<Symbol, RDF::URI>] variables
    # @return [Query]
    #
    # @overload self.describe(*variables, options)
    #   @param  [Array<Symbol, RDF::URI>] variables
    #   @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#describe
    def self.describe(*variables)
      options = variables.last.is_a?(Hash) ? variables.pop : {}
      self.new(:describe, options).describe(*variables)
    end

    ##
    # Creates a graph `CONSTRUCT` query.
    #
    # @param  [Array<RDF::Query::Pattern, Array>] patterns
    # @return [Query]
    #
    # @overload self.construct(*variables, options)
    #   @param  [Array<RDF::Query::Pattern, Array>] patterns
    #   @param  [Hash{Symbol => Object}]            options
    #   @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#construct
    def self.construct(*patterns)
      options = patterns.last.is_a?(Hash) ? patterns.pop : {}
      self.new(:construct, options).construct(*patterns) # FIXME
    end

    ##
    # @param  [Symbol, #to_s]          form
    # @overload self.construct(*variables, options)
    #   @param  [Symbol, #to_s]          form
    #   @param  [Hash{Symbol => Object}] options
    # @yield  [query]
    # @yieldparam [Query]
    def initialize(form = :ask, options = {}, &block)
      @subqueries = []
      @form = form.respond_to?(:to_sym) ? form.to_sym : form.to_s.to_sym
      super([], options, &block)
    end

    ##
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#ask
    def ask
      @form = :ask
      self
    end

    ##
    # @param  [Array<Symbol>] variables
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#select
    def select(*variables)
      @values = variables.map { |var| [var, RDF::Query::Variable.new(var)] }
      self
    end

    ##
    # @param  [Array<Symbol>] variables
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#describe
    def describe(*variables)
      @values = variables.map { |var|
        [var, var.is_a?(RDF::URI) ? var : RDF::Query::Variable.new(var)]
      }
      self
    end

    ##
    # @param  [Array<RDF::Query::Pattern, Array>] patterns
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#construct
    def construct(*patterns)
      options[:template] = build_patterns(patterns)
      self
    end

    # @param [RDF::URI] uri
    # @return [Query]
    # @see http://www.w3.org/TR/sparql11-query/#specifyingDataset
    def from(uri)
      options[:from] = uri
      self
    end
   
    ##
    # @param  [Array<RDF::Query::Pattern, Array>] patterns_queries
    #   splat of zero or more patterns followed by zero or more queries.
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#GraphPattern
    def where(*patterns_queries)
      subqueries, patterns = patterns_queries.partition {|pq| pq.is_a? SPARQL::Client::Query}
      @patterns += build_patterns(patterns)
      @subqueries += subqueries
      self
    end

    alias_method :whether, :where

    ##
    # @param  [Array<Symbol, String>] variables
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#modOrderBy
    def order(*variables)
      options[:order_by] = variables
      self
    end

    alias_method :order_by, :order

    ##
    # @param  [Array<Symbol, String>] variables
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#groupby
    def group(*variables)
      options[:group_by] = variables
      self
    end

    alias_method :group_by, :group

    ##
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#modDuplicates
    def distinct(state = true)
      options[:distinct] = state
      self
    end

    ##
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#modDuplicates
    def reduced(state = true)
      options[:reduced] = state
      self
    end

    ##
    # @param  [RDF::Value] graph_uri_or_var
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#queryDataset
    def graph(graph_uri_or_var)
      options[:graph] = case graph_uri_or_var
        when Symbol then RDF::Query::Variable.new(graph_uri_or_var)
        when String then RDF::URI(graph_uri_or_var)
        when RDF::Value then graph_uri_or_var
        else raise ArgumentError
      end
      self
    end

    ##
    # @param  [Integer, #to_i] start
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#modOffset
    def offset(start)
      slice(start, nil)
    end

    ##
    # @param  [Integer, #to_i] length
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#modResultLimit
    def limit(length)
      slice(nil, length)
    end

    ##
    # @param  [Integer, #to_i] start
    # @param  [Integer, #to_i] length
    # @return [Query]
    def slice(start, length)
      options[:offset] = start.to_i if start
      options[:limit] = length.to_i if length
      self
    end

    ##
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#prefNames
    def prefix(string)
      (options[:prefixes] ||= []) << string
      self
    end

    ##
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#optionals
    def optional(*patterns)
      (options[:optionals] ||= []) << build_patterns(patterns)
      self
    end

    ##
    # @return [Query]
    # @see    http://www.w3.org/TR/sparql11-query/#union
    def union(*patterns_list)
      options[:unions] ||= []
      patterns_list.each do |patterns|
        options[:unions] << build_patterns(patterns)
      end
      self
    end

    def union_with_bind_as(*pattern_list)
      options[:unions_with_bind] ||= []
      pattern_list.each do |patterns,bind_value,bind_var|
        options[:unions_with_bind] << [build_patterns(patterns), bind_value,bind_var]
      end
      self
    end

    def optional_union_with_bind_as(*pattern_list)
      options[:optional_unions_with_bind] ||= []

      pattern_list.each do |patterns,bind,filter|
        options[:optional_unions_with_bind] << [build_patterns(patterns), bind, filter]
      end
      self
    end

    def cache_key
      return nil if options[:from].nil? || options[:from].empty?
      from = options[:from]
      from = [from] unless from.instance_of?(Array)
      return Query.generate_cache_key(self.to_s,from)
    end

    def self.generate_cache_key(string,from)
      from = from.map { |x| x.to_s }.uniq.sort
      sorted_graphs = from.join ":"
      digest = Digest::MD5.hexdigest(string)
      from = from.map { |x| "sparql:graph:#{x}" }
      return { graphs: from, query: "sparql:#{sorted_graphs}:#{digest}" }
    end

    ##
    # @private
    def build_patterns(patterns)
      patterns.map do |pattern|
        case pattern
          when RDF::Query::Pattern then pattern
          else RDF::Query::Pattern.new(*pattern.to_a)
        end
      end
    end

    ##
    # @private
    def filter(string)
      ((options[:filters] ||= []) << string) if string and not string.empty?
      self
    end

    ##
    # @return [Boolean]
    def true?
      case result
        when TrueClass, FalseClass then result
        when RDF::Literal::Boolean then result.true?
        when Enumerable then !result.empty?
        else false
      end
    end

    ##
    # @return [Boolean]
    def false?
      !true?
    end

    ##
    # @return [Enumerable<RDF::Query::Solution>]
    def solutions
      result
    end

    ##
    # @yield  [statement]
    # @yieldparam [RDF::Statement]
    # @return [Enumerator]
    def each_statement(&block)
      result.each_statement(&block)
    end

    # Enumerates over each matching query solution.
    #
    # @yield  [solution]
    # @yieldparam [RDF::Query::Solution] solution
    # @return [Enumerator]
    def each_solution(&block)
      @solutions = result
      super
    end

    ##
    # @return [Object]
    def result
      @result ||= execute
    end

    ##
    # @return [Object]
    def execute
      raise NotImplementedError
    end

    ##
    # Returns the string representation of this query.
    #
    # @return [String]
    def to_s
      buffer = [form.to_s.upcase]

      case form
        when :select, :describe
          only_count = values.empty? and options[:count]
          buffer << 'DISTINCT' if options[:distinct] and not only_count
          buffer << 'REDUCED'  if options[:reduced]
          buffer << ((values.empty? and not options[:count]) ? '*' : values.map { |v| SPARQL::Client.serialize_value(v[1]) }.join(' '))
          if options[:count]
            options[:count].each do |var, count, aggregate|
              buffer << "( #{aggregate.to_s.upcase}(" + (options[:distinct] ? 'DISTINCT ' : '') +
                (var.is_a?(String) ? var : "?#{var}") + ') AS ' + (count.is_a?(String) ? count : "?#{count}") + ' )'
            end
          end
        when :construct
          buffer << '{'
          buffer += serialize_patterns(options[:template])
          buffer << '}'
      end

      from = options[:from]
      if from
        from = from.instance_of?(Array) ? options[:from] : [options[:from]]
        from.each do |from|
          buffer << "FROM #{SPARQL::Client.serialize_value(from)}"
        end
      end

      unless patterns.empty? && form == :describe
        buffer << 'WHERE {'

        if options[:graph]
          buffer << 'GRAPH ' + SPARQL::Client.serialize_value(options[:graph])
          buffer << '{'
        end

        @subqueries.each do |sq|
          buffer << "{ #{sq.to_s} } ."
        end

        def add_union_with_bind(patterns)
          include_union = nil
          buffer = []
          patterns.each do |pattern, options|
            buffer << include_union if include_union
            buffer << '{'
            buffer += serialize_patterns(pattern)
            if options[:filters]
              buffer += options[:filters].map do |filter|
                str = filter[:values].map do |val|
                  "?#{filter[:predicate]} = <#{val}>"
                end
                "FILTER(#{str.join(' || ')}) "
              end
            end

            if options[:binds]
              buffer += options[:binds].map { |bind| "BIND( \"#{bind[:value]}\" as ?#{bind[:as]})" }
            end


            buffer << '}'
            include_union = "UNION "
          end
          buffer
        end

        buffer += serialize_patterns(patterns)
        if options[:unions]
          include_union = nil
          options[:unions].each do |union_block|

            buffer << include_union if include_union
            buffer << '{'
            buffer += serialize_patterns(union_block)
            buffer << '} '
            include_union = "UNION "
          end
        end
        if options[:unions_with_bind]
          buffer <<  add_union_with_bind(options[:unions_with_bind])
        end

        if options[:optional_unions_with_bind] && !options[:optional_unions_with_bind].empty?
          buffer << 'OPTIONAL {'
          buffer <<  add_union_with_bind(options[:optional_unions_with_bind])
          buffer << '}'
        end

        if options[:optionals]
          options[:optionals].each do |patterns|
            buffer << 'OPTIONAL {'
            buffer += serialize_patterns(patterns)
            # mdorf, 11/15/2016 This is added to move the filters into the OPTIONAL clauses for AG compatibility
            buffer += patterns.map { |pattern| "FILTER(#{pattern.options[:filter]})" if pattern.options && pattern.options[:filter] }
            buffer << '}'
          end
        end
        if options[:filters]
          buffer += options[:filters].map { |filter| "FILTER(#{filter})" }
        end
        if options[:graph]
          buffer << '}' # GRAPH
        end

        buffer << '}' # WHERE
      end

      if options[:group_by]
        buffer << 'GROUP BY'
        buffer += options[:group_by].map { |var| var.is_a?(String) ? var : "?#{var}" }
      end

      if options[:order_by]
        buffer << 'ORDER BY'
        buffer += options[:order_by].map { |var| var.is_a?(String) ? var : "?#{var}" }
      end

      buffer << "OFFSET #{options[:offset]}" if options[:offset]
      buffer << "LIMIT #{options[:limit]}"   if options[:limit]
      options[:prefixes].reverse.each { |e| buffer.unshift("PREFIX #{e}") } if options[:prefixes]

      buffer.join(' ')
    end

    ##
    # @private
    def serialize_patterns(patterns)
      rdf_type = RDF.type
      patterns.map do |pattern|
        serialized_pattern = pattern.to_triple.each_with_index.map do |v, i|
          if i == 1 && v.equal?(rdf_type)
            'a' # abbreviate RDF.type in the predicate position per SPARQL grammar
          else
            SPARQL::Client.serialize_value(v)
          end
        end
        serialized_pattern.join(' ') + ' .'
      end
    end

    ##
    # Outputs a developer-friendly representation of this query to `stderr`.
    #
    # @return [void]
    def inspect!
      warn(inspect)
      self
    end

    ##
    # Returns a developer-friendly representation of this query.
    #
    # @return [String]
    def inspect
      sprintf("#<%s:%#0x(%s)>", self.class.name, __id__, to_s)
    end
  end
end; end
