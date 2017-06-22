
require 'set'
require_relative './utils'
require_relative './ast'

#
# Types
#

Generic = Struct.new(:id, :start, :finish)


class Type
  def ==(another)
    return false unless another.class == self.class
    return false unless another.instance_variables == instance_variables
    instance_variables.each do |i|
      if instance_variable_get(i) != another.instance_variable_get(i)
        return false
      end
    end
    true
  end

  def inspect
    attrs = instance_variables
      .map {|a| "#{a.to_s[1..a.to_s.length]}=#{instance_variable_get(a)}"}
      .join(", ")
    "#{self.class}(#{attrs})"
  end
end

class Unknown < Type ; end

class Literal < Type

  attr_accessor :subtype

  # valid subtypes:
  # :integer
  # :string
  # :object

  def initialize(subtype)
    @subtype = subtype
  end

end

class Open_object < Type

  attr_accessor :fields

  # .fields is a dictionary from
  # the name of the field to it's
  # generic. This is important
  # because then the inference of
  # the fields works transparently
  # as we infer the type of the
  # generic.

  def initialize(fields)
    @fields = fields
  end

end

class Function < Type

  attr_accessor :takes, :returns

  def initialize(takes:, returns:)
    @takes = takes
    @returns = returns
  end

end


$generic_counter = 0

def new_generic(start, finish)
  Generic.new($generic_counter, start, finish)
  $generic_counter += 1
end


#
# Ast
#

# reopening the class to add
# type-specific features 
class Token
  
  # lazily make the generics!
  def generic
    if @generic
      @generic
    else
      @generic = new_generic(@start, @finish)
    end
  end

end

class Typetable

  attr_reader :type_mapping

  def initialize

    # map from sets of Generics to their type.
    #
    # this is the source of truth.
    @type_mapping = {}
  end

  def get_type_of_generic(generic)
    @type_mapping.each do |k, v|
      if k.include? generic
        return [k,v]
      end
    end

    # it should never be nil.
    [nil, nil]
  end

  def already_has(type)
    @type_mapping.map {|k, v| k.include?(type)}.any?
  end

  def error_types(a, b)
    raise "Type error: #{type} and #{constrained} conflict"
  end

  def constrain_generic(generic, constrained)
    set, type = get_type_of_generic(generic)
    if set.nil? and type.nil?
      set = Set.new([generic])
      type = Unknown.new
    elsif set.nil? or type.nil?
      raise "Did not prepare for this situation"
    end

    @type_mapping[set] = constrain(type, constrained)
  end

  def alias_generics(a, b)
    aset, atype = get_type_of_generic(a)
    bset, btype = get_type_of_generic(b)

    # if they are the same don't do anything
    return if aset == bset and not aset.nil?

    if not btype and not atype
      @type_mapping[Set.new([a, b])] = Unknown.new
    elsif btype and atype
      @type_mapping.delete(aset)
      @type_mapping.delete(bset)
      ctype = constrain atype btype
      @type_mapping[aset.union bset] = ctype
    else

      if btype
        aset, bset = bset, aset
        atype, btype = btype, atype
        a, b = b, a
      end
      # now atype is not nil
      aset << b
    end
  end

  def constrain(type, constrained)
    return constrained if type.class == Unknown
    return type if constrained.class == Unknown
    return type if type == constrained

    case type.class
    when Literal
      # in the future, use line numbers.
      error_types(type, constrained)
    when Function
      error_types(type, constrained) unless constrained.class == Function
      alias_generics(type.takes, constrained.takes)
      alias_generics(type.returns, constrained.returns)
      # they are asserted to be the same by the above calls to alias_generics
      return atype
    when Open_object
      error_types(type, constrained) unless constrained.class == Open_object
      raise "unimplemented"
      # you have to iterate over each field,
      # construct a new Open_object that has
      # a union of the two sets of feilds,
      # and then call `alias_generics` for
      # each field.
    else
      raise "unimplemented class #{type}"
    end
  end

end

#
# Logic for keeping track of name stack
#


class Aliaser

  def initialize(types)
    @types = types
    @names = []
  end

  def get(name)
    @names.map { |x| x[name] }.last
  end

  def add(stack)
    @names << stack
  end

  def drop
    @names.pop
  end

  def post
    lambda do |a|

      aliased(a)

      return unless is_let_in(a) or a.is_a?(Block)
      drop
    end
  end

  def is_let_in(ast)
    ast.is_a?(Parens) and
      is_ident(ast.children[0], "let_in")
  end

  def record_let(ast)
    return unless is_let_in(ast)

    @types.alias_generics(ast.generic, ast.children[2].generic)
    add({ast.children[1].data => ast.generic})
  end

  def record_block(ast)
    return unless ast.is_a?(Block)

    arguments = ast.arguments.map do |a|
      [a.data, a.generic]
    end.to_h

    add(arguments)
  end

  def aliased(ast)

    # includes everything, and tokens
    ast.collect(cls: Token) do |tok|

      # this is kind of sketchy, but here's what's happening:
      #
      # `aliased` is called on every `collect` in `aliases_for_names`
      # we only alias the first time it's called, and we do this
      # by checking if to see if the token already has it's type in
      # the type table. (so it's important not much comes before aliases_for_names)
      # but aliases_for_names is a very important function, and no other typing
      # things really make sense without having the names taken care of...
      # so it's reasonable to expect this to be the first one.
      if (generic = get(tok.data)) and not @types.already_has(tok.generic)
        # puts "HI " + tok.to_s
        @types.alias_generics(tok.generic, generic)
      end
    end

  end
end


#
# Logic for adding types
#

class Typer

  def initialize(root)
    @root = root

    @types = Typetable.new
  end

  def produce_ast

    # clean up tree first!
    # get rid of extra parentheses

    convert_let_statements

    aliases_for_names # (let statements and block arguments)

    constraints_for_token_literals
    constraints_for_block_literals
    constraints_for_function_application
    constraints_for_field_access

    @root
  end

  def stringify_types
    @types.type_mapping.map do |k, v|
      [k.to_a, v]
    end.to_h.inspect
  end

  private

    def convert_let_statements
      # this is a tree operation that
      # transforms 'define x 3' within a
      # block to let_in x 3 [ ]
      # with the rest of the lines of the block in the
      #
      # This means that (define x 3) + 2 or something
      # is invalid because 'define' is just a let statement.
      #
      # Maybe don't do this within class definitions?

      @root.collect(cls: Block) do |block|
        i = 0
        while i != block.children.length do
          child = block.children[i]
          i += 1
          next if child.class != Parens
          next if not is_ident(child.children[0], "define")

          # construct new child
          new_scope = Block.new(block.children[(i)..block.children.length] || [], [], child)
          child.children << new_scope
          child.children[0].data = 'let_in'

          # ignore the rest of the children
          block.children = block.children[0..(i-1)]
        end
      end

    end

    def aliases_for_names

      aliaser = Aliaser.new(@types)

      # cls: Ast by default
      @root.collect(post: aliaser.post) do |ast|
        aliaser.record_let(ast)
        aliaser.record_block(ast)
      end
    end

    def constraints_for_token_literals
      @root.collect(cls: Token) do |tok|
        if tok.class == Token
          if tok.token == :ident and tok.data.valid_integer?

            @types.constrain_generic(tok.generic, Literal.new(:integer))

          elsif tok.token == :string

            @types.constrain_generic(tok.generic, Literal.new(:string))

          end
        end
      end
    end

    def constraints_for_block_literals

    end

    def constraints_for_object_literals

    end

    def constraints_for_function_application

    end

    def constraints_for_field_access

    end

end

