defmodule SymphonyElixir.YouGile.Config do
  @moduledoc """
  YouGile-specific configuration read from the `yougile:` YAML section.
  """

  @behaviour SymphonyElixir.TrackerConfig

  @default_columns %{
    "todo" => nil,
    "in-progress" => nil,
    "done" => nil,
    "cancelled" => nil
  }

  @spec board_id() :: String.t() | nil
  def board_id do
    normalize_string(section_value("board_id"))
  end

  @spec token() :: String.t() | nil
  def token do
    normalize_string(System.get_env("YOUGILE_TOKEN"))
  end

  @spec columns() :: %{String.t() => String.t() | nil}
  def columns do
    case section_value("columns") do
      value when is_map(value) ->
        Map.merge(@default_columns, normalize_columns(value))

      _ ->
        @default_columns
    end
  end

  @spec column_id(String.t()) :: String.t() | nil
  def column_id(state_name) do
    Map.get(columns(), normalize_state(state_name))
  end

  @spec state_for_column(String.t()) :: String.t() | nil
  def state_for_column(column_id) when is_binary(column_id) do
    columns()
    |> Enum.find_value(fn {state, cid} -> if cid == column_id, do: state end)
  end

  @spec priority_sticker_id() :: String.t() | nil
  def priority_sticker_id do
    normalize_string(section_value("priority_sticker_id"))
  end

  @impl SymphonyElixir.TrackerConfig
  def validate! do
    cond do
      !is_binary(token()) ->
        {:error, "YouGile token missing — set YOUGILE_TOKEN env var"}

      !is_binary(board_id()) ->
        {:error, "YouGile board_id missing — set yougile.board_id in WORKFLOW.md"}

      !has_any_column_ids?() ->
        {:error, "YouGile columns missing — set yougile.columns in WORKFLOW.md with at least one state-to-column mapping"}

      true ->
        :ok
    end
  end

  defp has_any_column_ids? do
    columns()
    |> Map.values()
    |> Enum.any?(&is_binary/1)
  end

  defp section_value(key) do
    Map.get(SymphonyElixir.Config.section("yougile"), key)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_state(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp normalize_columns(columns_map) when is_map(columns_map) do
    Enum.reduce(columns_map, %{}, fn {key, value}, acc ->
      normalized_key = normalize_state(to_string(key))
      normalized_value = normalize_string(to_string(value))
      Map.put(acc, normalized_key, normalized_value)
    end)
  end
end
