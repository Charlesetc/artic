
require 'set'
require_relative './phonebook'
require_relative './files'
require_relative './utils'
require_relative './ast'
require_relative './triage'
require_relative './types'

#
# Logic for adding types
#

def deepcopy(ast)
  if ast.is_a? Array
    return ast.map { |x| deepcopy(x) }
  elsif ast.is_a? Hash
    return ast.map { |k, x| [k, deepcopy(x)] }.to_h
  elsif ast.is_a?(Symbol) || ast.is_a?(Fixnum)
    return ast
  end
  ast = ast.clone
  ast.instance_variables.each do |var|
    ast.instance_variable_set(
      var,
      deepcopy(ast.instance_variable_get(var))
    )
  end
  ast
end


class Typer
  include Triage
  alias_method :run, :run_triage

  def initialize(file, phonebook: nil)
    @file = file
    @phonebook = phonebook || Phonebook.new
  end

  def before_triage(ast)
    raise "already triaged" if ast.type
  end

  def execute_function(function_type)
    returned_values =
      @phonebook.lookup_function(function_type) do |ast, arguments, first_time|
        if first_time
          ast.arguments.each_with_index do |name, i|
            @phonebook.insert(name.data, arguments[i])
          end
          ast.children.each { |x| triage(x) }
        end

        ast.children.last ? ast.children.last.type : UnitType.new
      end

    # assert these are all equal/mergeable and return it
    ret = returned_values.pop
    returned_values.each do |val|
      ret = merge_types(ret, val, reason: "function returns of " +
                        "variants have to be the same",
                        ast_for_error: function_type)
    end
    ret
  end

  def handle_while(stmt)
    # I'm not sure what to make
    # of a return value from a while
    # statement... it seems
    # like a pretty imperative thing.
    stmt.type = UnitType.new
  end

  def handle_inlay(stmt)
    stmt.type = UnitType.new
  end

  def handle_update(update)
    # This could be redesigned with patterns nicely.
    #
    # TODO: assert we've got everything
    # here we need, in the right format
    #
    newvalue = update.children[2]
    unwrap_child?(update, 1)
    var = update.children[1]

    if var.class == Dot_access
      child = var.child

      # we can deal with field assignments later, etc
      raise("Assignments to fields have to be on identifiers") unless child.token == :ident

      # sets the type for the return value.
      var.type = merge_types(
        var.type,
        newvalue.type,
        reason: "updates must have the same type as the original",
        ast_for_error: newvalue,
      )

      previous = @phonebook.lookup(@file.name, child.data)
      error_ast(var, "Undefined reference: #{var.data}") if previous.nil?

      # it's gotta be an object.
      # we already triaged the
      # dotaccess so the types
      # work out
      previous.type.fields[var.name] = var.type
      return
    else

      # we can deal with field assignments later, etc
      raise("Assignments should be to identifier or fields") unless var.token == :ident

      previous = @phonebook.lookup(@file.name, var.data)
      error_ast(var, "Undefined reference: #{var.data}") if previous.nil?

      # Type comparison!
      # # must update with variant information if needed.

      previous.type = merge_types(
        previous.type,
        newvalue.type,
        reason: "updates must have the same type as the original",
        ast_for_error: newvalue,
      )

      # the type is whatever we were assigning
      update.type = previous.type
    end
  end

  def handle_type_check(check)
    checked = check.children[1]
    unwrap_child?(check, 2)
    annotation = check.children[2]
    handle_type_check_on_checked(checked, checked.type, annotation)
    check.type = checked.type
  end

  def handle_type_check_on_checked(checked, checked_type, annotation)
    if annotation.class == Object_literal
      if checked_type.class != ObjectType
        error_ast_type(checked, type: checked_type, expected: "an object, as was asserted")
      end

      annotation.fields.each do |name, value|
        checked_value = checked_type.fields[name]
        handle_type_check_on_checked(checked, checked_value, value)
      end

    elsif annotation.token == :ident
      cls = parse_annotation(annotation)
      if checked_type.class != cls
        error_ast_type(checked, type: checked_type, expected: cls.to_s + ", as was asserted")
      end
    else
      error_ast(annotation, "expected ident or object in type annotation")
    end
  end

  def handle_if(ifstmt)
    c = ifstmt.children

    unless c[1].type.class == BoolType
      error_ast_type(c[1], expected: "a boolean")
    end

    if c[3]
      ifret = c[2].children.last
      elseret = c[3].children.last

      ifrett = ifret ? ifret.type : UnitType.new
      elserett = elseret ? elseret.type : UnitType.new

      # Type comparison!
      unless ifrett == elserett
        error_ast_type(ifret, expected: "#{elserett.inspect}, because if statement branches must have the same return type")
      end

      type = merge_types(
        ifrett,
        elserett,
        reason: "if statement branches must have the same return type",
        ast_for_error: ifstmt,
      )

      ifstmt.type = type
    else
      # if statements that don't have else branches
      # will always return unit.
      # Specifically, whatever the last item of their
      # block is, it's not paid attention to.
      ifstmt.type = UnitType.new
    end
  end

  def handle_function_call(parens)
    first = parens.children[0]
    case parens.children.length
    when 0
      parens.type = UnitType.new
    when 1
      parens.type = first.type
    else
      error_ast_type(first, expected: "a Function") unless first.type.class == FunctionType
      arguments = parens.children[1...parens.children.length]

      # If greater
      if first.type.arity > arguments.length
        parens.type = first.type.add_arguments(arguments)
      else
        # If less than
        if first.type.arity < arguments.length
          if arguments.length == 1 and
             first.type.arity == 0 and
             arguments[0].type.class == UnitType
            arguments = [] # and continue on to the execute function
          else
            error_ast(first, "Takes #{first.type.arity} arguments but got #{arguments.length}")
          end
        end

        # if equal:
        return_type = execute_function(first.type.add_arguments(arguments))
        parens.type = return_type if return_type
      end
    end
  end

  def handle_true(token)
    token.type = BoolType.new
  end

  def handle_false(token)
    token.type = BoolType.new
  end

  def handle_token(token)
    case token.token
    when :ident
      if token.data.valid_integer?
        token.type = IntegerType.new
      elsif token.data.valid_float?
        token.type = FloatType.new
      else
        number = @phonebook.lookup(@file.name, token.data)
        error_ast(token, "Undefined reference: #{token.data}") if number.nil?
        token.type = number.type
      end
    when :string
      token.type = StringType.new
    end
  end

  def handle_define(item, toplevel:)
    # ASSERT item.children[1] exists and is ident
    # ASSERT item.children[2] exists
    if toplevel
      @phonebook.insert_toplevel(@file.name, item.children[1].data, item.children[2])
    else
      @phonebook.insert(item.children[1].data, item.children[2])
    end
  end

  def handle_object_literal(object)
    object.type = ObjectType.new(
      object.fields.map {|k,v| [k, v.type]}.to_h
    )
  end

  def handle_dot_access(dot)
    unless dot.child.type.class == ObjectType
      error_ast_type(dot.child, expected: "object")
    end

    type = dot.child.type.fields[dot.name]
    if type
      dot.type = type
    else
      error_ast_type(dot.child, expected: "object with #{dot.name} field")
    end
  end

  def handle_single_variant(ident)
    name = ident.data
    location = [ident.start, ident.finish]
    ident.type = VariantType.start(
      name,
      [],
      location
    )
  end

  def handle_variant(parens)
    name = parens.children[0].data
    argtypes = parens.children.drop(1).map do |child|
      child.type
    end
    location = [parens.start, parens.finish]

    parens.type = VariantType.start(
      name,
      argtypes,
      location
    )
  end

  def handle_block(block)
    name = @phonebook.closure_number
    block.type = FunctionType.new(
      [name],
      block.arguments.length
    )
    @phonebook.insert_block(name, block)
  end

  def handle_require(item)
    # this function parses a file,
    # and then makes a new typer with the
    # same phonebook that goes and fills in
    # the initial top level definitions it
    # encounters.
    #
    # Finally, we make a new object with
    # the name required and define it
    # for this module. This object
    # has references to each of the
    # definitions in the file we parsed.

    # support directories in the future
    filename = item.children[1].data + ".brie"
    filename = same_dir_as(@file.name, filename)

    filetyper = Typer.new(SourceFile.new(filename), phonebook: @phonebook)
    filetyper.index_file

    defs = @phonebook.dump_definitions_for_file(filename)
    error_ast(item, "Can't require files with no definitions") if defs.empty?

    defs = defs.map { |k, v| [k, [v]] }.to_h
    object = Object_literal.new(defs)
    object.type = ObjectType.new(
      object.fields.map do |k,v|
        # they are all parens
        # with one value.
        v.type = v.children[0].type
        [k, v.type]
      end.to_h
    )

    # define it locally
    #
    @phonebook.insert_toplevel(@file.name, item.children[1].data, object)
  end

  def handle_match(ast, expression, sections)

    # Step 1: check to make sure
    #         the types of the variants
    #         can match the type of the expression

    error_ast_type(ast, expected: "a varient type, since it's a match statement") if expression.type.class != VariantType

    sections.each do |section|
      expected_types = expression.type.names[section.name]

      if expected_types
        error_ast_type(
          section.pattern,
          type: expression.type,
          expected: "a #{section.name} with #{section.arguments.length} arguments"
        ) unless expected_types.length == section.arguments.length
      end

      # now we have more information than the 'pattern'
      section.expected_types = expected_types
    end

    # if there's no type, then it's not
    # really an option now is it.
    sections = sections.select { |s| s.expected_types }


    # Step 2: go through sections and define
    #         the proper names (and their types)
    #         for each one. Then triage them.

    sections.each do |section|
      @phonebook.enter
      section.arguments.each_with_index do |arg, i|
        error_ast(arg, "match argument must be an identifier") if arg.token != :ident

        arg.type = section.expected_types[i]
        @phonebook.insert(arg.data, arg)
      end
      section.expressions.each { |x| triage(x) }
      section.return_type = section.expressions.last ?
                            section.expressions.last.type :
                            UnitType.new
      @phonebook.exit
    end


    # Step 3: Find out the return type of each
    #         and make sure that they all merge

    sections = sections.clone
    ret = sections.pop.return_type
    sections.each do |section|
      ret = merge_types(
        ret, section.return_type,
        reason: "all sections of match have to have the same type",
        ast_for_error: ast
      )
    end

    # Step 4: Set the return type of the match
    #         expression

    ast.type = ret
  end

end

