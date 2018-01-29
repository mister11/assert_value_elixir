defmodule AssertValue.Parser do

  # This is internal parser error
  # In theory we parse any valid Elixir code and should not face it
  defmodule ParseError do
    defexception [message: "Unable to parse assert_value arguments"]
  end

  # Returns {prefix, expected, suffix, indentation}
  #
  # Split file contents (code) to three parts:
  #   * everything before expected (prefix)
  #   * expected as it is formatted in code include quotes (expected)
  #   * everything after expected (suffix)
  #
  #   code == prefix <> expected <> suffix
  #
  def parse_expected(filename, line_num, assertion_ast, actual_ast, expected_ast) do
    {prefix, suffix} =
      File.read!(filename)
      |> String.split("\n")
      |> Enum.split(line_num - 1)

    prefix = prefix |> Enum.join("\n")
    suffix = suffix |> Enum.join("\n")

    [_, indentation, assert_value, rest] =
      Regex.run(~r/(^\s*)(assert_value\s*)(.*)/s, suffix)

    prefix = prefix <> "\n" <> indentation <> assert_value

    # We enclose parsing in try/rescue because parser code is executed
    # inside genserver. Exceptions raised in genserver produce unreadable
    # Erlang error messages so it is better to pass theese exceptions outside
    # genserver and reraise them to show readable Elixir error messages
    try do
      {assertion, suffix} = find_ast_in_code(rest, assertion_ast)
      {assertion, left_parens, right_parens} = trim_parens(assertion)
      prefix = prefix <> left_parens
      suffix = right_parens <> suffix

      {prefix, rest, suffix} =
        if actual_ast == :_not_present_ do
          {prefix <> assertion, "", suffix}
        else
          {actual, rest} = find_ast_in_code(assertion, actual_ast)
          {prefix <> actual, rest, suffix}
        end

      {prefix, expected, suffix} =
        if expected_ast == :_not_present_ do
          {prefix <> " == ", "", suffix}
        else
          [_, operator, _, rest] = Regex.run(~r/((\)|\s)*==\s*)(.*)/s, rest)
          {expected, rest} = find_ast_in_code(rest, expected_ast)
          {prefix <> operator, expected, rest <> suffix}
        end

      {prefix, expected, suffix, indentation}
    rescue
      AssertValue.Parser.ParseError ->
        {:error, :parse_error}
    end
  end

  # Private

  # Finds the part of the code with the same AST as second parameter
  # Return pair {accumulator, rest}
  #
  #   iex(1) find_ast_in_code("(1 + 2) == 3", {:+, [], [1, 2]})
  #   #=> {"(1 + 2)", "== 3"}
  #
  # Recursively take one character from code, append it to accumulator, and
  # compare accumulator's AST with reference
  #
  # Corner Case:
  #
  # * floats with trailing zeros
  #   AST for "42.00000" is 42.0
  #   so we need to check that the rest of the code does not contain
  #   leading zeros. They all belong to parsed value
  #
  defp find_ast_in_code(code, ast, accumulator \\ "") do
    if code_match_ast?(accumulator, ast) && (String.at(code, 0) != "0") do
      {accumulator, code}
    else
      case String.next_grapheme(code) do
        {first_grapheme, rest} ->
          find_ast_in_code(rest, ast, accumulator <> first_grapheme)
        nil ->
          # No more characters left and still not match?
          raise AssertValue.Parser.ParseError
      end
    end
  end

  # Compare code string with ast
  # Returns true if code's AST match the second parameter
  # There is a corner case for empty string in Elixir < 1.6.0
  #
  #   # Elixir 1.5.3
  #   iex(1)> Code.string_to_quoted(nil)
  #   {:ok, nil}
  #   iex(1)> Code.string_to_quoted("")
  #   {:ok, nil}
  #
  #   # Elixir 1.6.0-rc.0
  #   iex(1)> Code.string_to_quoted(nil)
  #   {:ok, nil}
  #   iex(1)> Code.string_to_quoted("")
  #   {:ok, {:__block__, [], []}}
  #
  # We are sure that when AST is nil it is really nil because we have
  # special :_not_present_ token for empty ASTs
  defp code_match_ast?(code, ast) do
    case Code.string_to_quoted(code) do
      {:ok, quoted} ->
        quoted = if is_binary(quoted) do
          String.replace(quoted, "<NOEOL>\\n", "")
        else
          quoted
        end
        ast_match?(quoted, ast) and !(code == "" and ast == nil)
      _ ->
        false
    end
  end

  defp ast_match?(a, b) do
    remove_lines_meta(a) == remove_lines_meta(b)
  end

  # recursively delete meta information about line numbers from AST
  # iex> remove_lines_meta({:foo, [line: 10], []})
  # {:foo, [], []}
  defp remove_lines_meta(ast) do
    cleaner = &Keyword.delete(&1, :line)
    Macro.prewalk(ast, &Macro.update_meta(&1, cleaner))
  end

  # Try to trim parens and whitespaces around the code recursively
  # while code's AST remains the same
  #
  # Return {trimmed_code, left_parens_acc, right_parens_acc)
  #
  #   trim_parens("  ( (foo  ) ) ")
  #   => {"foo", "  ( (", "  ) ) "}
  #
  defp trim_parens(code, left_parens_acc \\ "", right_parens_acc \\ "") do
    with [_, lp, trimmed, rp] <-
        Regex.run(~r/^(\s*\(\s*)(.*)(\s*\)\s*)$/s, code),
      {:ok, original_code_ast} <- Code.string_to_quoted(code),
      {:ok, trimmed_code_ast} <- Code.string_to_quoted(trimmed),
      true <- ast_match?(trimmed_code_ast, original_code_ast) do
        trim_parens(trimmed, left_parens_acc <> lp, rp <> right_parens_acc)
    else
      _ ->
        {code, left_parens_acc, right_parens_acc}
    end
  end

end
