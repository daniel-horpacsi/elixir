defmodule Module.Types.Pattern do
  @moduledoc false

  alias Module.Types.Of
  import Module.Types.{Helpers, Descr}

  @guard atom([true, false, :fail])

  @doc """
  Handles patterns and guards at once.
  """
  # TODO: The expected types for patterns/guards must always given as arguments.
  # Meanwhile, it is hardcoded to dynamic.
  def of_head(patterns, guards, meta, stack, context) do
    pattern_stack = %{stack | meta: meta}

    with {:ok, types, context} <-
           map_reduce_ok(patterns, context, &of_pattern(&1, pattern_stack, &2)),
         {:ok, _, context} <-
           map_reduce_ok(guards, context, &of_guard(&1, {@guard, &1}, stack, &2)),
         do: {:ok, types, context}
  end

  ## Patterns

  @doc """
  Return the type and typing context of a pattern expression
  with no {expected, expr} pair. of_pattern/4 must be preferred
  whenever possible as it adds more context to errors.
  """
  def of_pattern(expr, stack, context) do
    # TODO: Remove the hardcoding of dynamic
    of_pattern(expr, {dynamic(), expr}, stack, context)
  end

  @doc """
  Return the type and typing context of a pattern expression with
  the given {expected, expr} pair or an error in case of a typing conflict.
  """

  # ^var
  def of_pattern({:^, _meta, [var]}, expected_expr, stack, context) do
    Of.intersect(Of.var(var, context), expected_expr, stack, context)
  end

  # left = right
  # TODO: Track variables and handle nesting
  def of_pattern({:=, _meta, [left_expr, right_expr]}, {expected, expr}, stack, context) do
    case {is_var(left_expr), is_var(right_expr)} do
      {true, false} ->
        with {:ok, type, context} <- of_pattern(right_expr, {expected, expr}, stack, context) do
          of_pattern(left_expr, {type, expr}, stack, context)
        end

      {false, true} ->
        with {:ok, type, context} <- of_pattern(left_expr, {expected, expr}, stack, context) do
          of_pattern(right_expr, {type, expr}, stack, context)
        end

      {_, _} ->
        with {:ok, _, context} <- of_pattern(left_expr, {expected, expr}, stack, context),
             {:ok, _, context} <- of_pattern(right_expr, {expected, expr}, stack, context),
             do: {:ok, dynamic(), context}
    end
  end

  # %var{...} and %^var{...}
  def of_pattern(
        {:%, _meta, [struct_var, {:%{}, _meta2, args}]} = expr,
        expected_expr,
        stack,
        context
      )
      when not is_atom(struct_var) do
    with {:ok, struct_type, context} <-
           of_pattern(struct_var, {atom(), expr}, %{stack | refine: false}, context),
         {:ok, map_type, context} <-
           of_open_map(args, [__struct__: struct_type], expected_expr, stack, context),
         {_, struct_type} = map_fetch(map_type, :__struct__),
         {:ok, _struct_type, context} <-
           of_pattern(struct_var, {struct_type, expr}, stack, context) do
      {:ok, map_type, context}
    end
  end

  # %Struct{...}
  def of_pattern({:%, _meta, [module, {:%{}, _, args}]} = expr, expected_expr, stack, context)
      when is_atom(module) do
    with {:ok, actual, context} <-
           Of.struct(expr, module, args, :merge_defaults, stack, context, &of_pattern/3) do
      Of.intersect(actual, expected_expr, stack, context)
    end
  end

  # %{...}
  def of_pattern({:%{}, _meta, args}, expected_expr, stack, context) do
    of_open_map(args, [], expected_expr, stack, context)
  end

  # <<...>>>
  def of_pattern({:<<>>, _meta, args}, _expected_expr, stack, context) do
    case Of.binary(args, :pattern, stack, context, &of_pattern/4) do
      {:ok, context} -> {:ok, binary(), context}
      {:error, context} -> {:error, context}
    end
  end

  # _
  def of_pattern({:_, _meta, _var_context}, {expected, _expr}, _stack, context) do
    {:ok, expected, context}
  end

  # var
  def of_pattern({name, meta, ctx} = var, {expected, expr}, stack, context)
      when is_atom(name) and is_atom(ctx) do
    case stack do
      %{refine: true} ->
        Of.refine_var(var, expected, expr, stack, context)

      %{refine: false} ->
        version = Keyword.fetch!(meta, :version)

        case context do
          %{vars: %{^version => %{type: type}}} ->
            Of.intersect(type, {expected, expr}, stack, context)

          %{} ->
            {:ok, expected, context}
        end
    end
  end

  def of_pattern(expr, expected_expr, stack, context) do
    of_shared(expr, expected_expr, stack, context, &of_pattern/4)
  end

  # TODO: Track variables inside the map (mirror it with %var{} handling)
  defp of_open_map(args, extra, expected_expr, stack, context) do
    result =
      reduce_ok(args, {[], context}, fn {key, value}, {fields, context} ->
        with {:ok, value_type, context} <- of_pattern(value, stack, context) do
          if is_atom(key) do
            {:ok, {[{key, value_type} | fields], context}}
          else
            {:ok, {fields, context}}
          end
        end
      end)

    with {:ok, {fields, context}} <- result do
      Of.intersect(open_map(extra ++ fields), expected_expr, stack, context)
    end
  end

  @doc """
  Refines the type variables in the typing context using type check guards
  such as `is_integer/1`.
  """

  def of_guard(expr, stack, context) do
    of_guard(expr, {dynamic(), expr}, stack, context)
  end

  # %Struct{...}
  def of_guard({:%, _, [module, {:%{}, _, args}]} = expr, _expected_expr, stack, context)
      when is_atom(module) do
    Of.struct(expr, module, args, :skip_defaults, stack, context, &of_guard/3)
  end

  # %{...}
  def of_guard({:%{}, _meta, args}, _expected_expr, stack, context) do
    Of.closed_map(args, stack, context, &of_guard/3)
  end

  # <<>>
  def of_guard({:<<>>, _meta, args}, _expected_expr, stack, context) do
    case Of.binary(args, :expr, stack, context, &of_guard/4) do
      {:ok, context} -> {:ok, binary(), context}
      # It is safe to discard errors from binary inside expressions
      {:error, context} -> {:ok, binary(), context}
    end
  end

  # var.field
  def of_guard({{:., _, [callee, key]}, _, []} = expr, _expected_expr, stack, context)
      when not is_atom(callee) do
    with {:ok, type, context} <- of_guard(callee, stack, context) do
      Of.map_fetch(expr, type, key, stack, context)
    end
  end

  # Remote
  def of_guard({{:., _, [:erlang, function]}, _, args} = expr, _expected_expr, stack, context)
      when is_atom(function) do
    with {:ok, args_type, context} <-
           map_reduce_ok(args, context, &of_guard(&1, stack, &2)) do
      Of.apply(:erlang, function, args_type, expr, stack, context)
    end
  end

  # var
  def of_guard(var, _expected_expr, _stack, context) when is_var(var) do
    {:ok, Of.var(var, context), context}
  end

  def of_guard(expr, expected_expr, stack, context) do
    of_shared(expr, expected_expr, stack, context, &of_guard/4)
  end

  ## Shared

  # :atom
  defp of_shared(atom, {expected, expr}, stack, context, _fun) when is_atom(atom) do
    if atom_type?(expected, atom) do
      {:ok, atom([atom]), context}
    else
      {:error, Of.incompatible_warn(expr, expected, atom([atom]), stack, context)}
    end
  end

  # 12
  defp of_shared(literal, {expected, expr}, stack, context, _fun) when is_integer(literal) do
    if integer_type?(expected) do
      {:ok, integer(), context}
    else
      {:error, Of.incompatible_warn(expr, expected, integer(), stack, context)}
    end
  end

  # 1.2
  defp of_shared(literal, {expected, expr}, stack, context, _fun) when is_float(literal) do
    if float_type?(expected) do
      {:ok, float(), context}
    else
      {:error, Of.incompatible_warn(expr, expected, float(), stack, context)}
    end
  end

  # "..."
  defp of_shared(literal, {expected, expr}, stack, context, _fun) when is_binary(literal) do
    if binary_type?(expected) do
      {:ok, binary(), context}
    else
      {:error, Of.incompatible_warn(expr, expected, binary(), stack, context)}
    end
  end

  # []
  defp of_shared([], _expected_expr, _stack, context, _fun) do
    {:ok, empty_list(), context}
  end

  # [expr, ...]
  defp of_shared(exprs, _expected_expr, stack, context, fun) when is_list(exprs) do
    case map_reduce_ok(exprs, context, &fun.(&1, {dynamic(), &1}, stack, &2)) do
      {:ok, _types, context} -> {:ok, non_empty_list(), context}
      {:error, reason} -> {:error, reason}
    end
  end

  # {left, right}
  defp of_shared({left, right}, expected_expr, stack, context, fun) do
    of_shared({:{}, [], [left, right]}, expected_expr, stack, context, fun)
  end

  # left | []
  defp of_shared({:|, _meta, [left_expr, []]}, _expected_expr, stack, context, fun) do
    fun.(left_expr, {dynamic(), left_expr}, stack, context)
  end

  # left | right
  defp of_shared({:|, _meta, [left_expr, right_expr]}, _expected_expr, stack, context, fun) do
    case fun.(left_expr, {dynamic(), left_expr}, stack, context) do
      {:ok, _, context} ->
        fun.(right_expr, {dynamic(), right_expr}, stack, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # left ++ right
  defp of_shared(
         {{:., _meta1, [:erlang, :++]}, _meta2, [left_expr, right_expr]},
         _expected_expr,
         stack,
         context,
         fun
       ) do
    # The left side is always a list
    with {:ok, _, context} <- fun.(left_expr, {dynamic(), left_expr}, stack, context),
         {:ok, _, context} <- fun.(right_expr, {dynamic(), right_expr}, stack, context) do
      # TODO: Both lists can be empty, so this may be an empty list,
      # so we return dynamic for now.
      {:ok, dynamic(), context}
    end
  end

  # {...}
  defp of_shared({:{}, _meta, exprs}, _expected_expr, stack, context, fun) do
    case map_reduce_ok(exprs, context, &fun.(&1, {dynamic(), &1}, stack, &2)) do
      {:ok, _, context} -> {:ok, tuple(), context}
      {:error, reason} -> {:error, reason}
    end
  end
end
