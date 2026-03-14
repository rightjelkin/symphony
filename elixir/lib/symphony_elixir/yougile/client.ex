defmodule SymphonyElixir.YouGile.Client do
  @moduledoc """
  YouGile REST API client for task tracking via columns.
  """

  require Logger
  alias SymphonyElixir.{YouGile, Issue}

  @base_url "https://yougile.com/api-v2"
  @per_page 100

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    with {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      columns = YouGile.Config.columns()

      candidate_states = ["todo", "in-progress"]

      column_ids =
        candidate_states
        |> Enum.map(&Map.get(columns, &1))
        |> Enum.filter(&is_binary/1)

      fetch_tasks_for_columns(column_ids, request_fun, token, columns)
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    if state_names == [], do: {:ok, []}, else: do_fetch_issues_by_states(state_names, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    if issue_ids == [], do: {:ok, []}, else: do_fetch_issue_states_by_ids(issue_ids, opts)
  end

  @spec fetch_comments(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_comments(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/chats/#{task_id}/messages?limit=#{@per_page}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: %{"content" => content}}} when is_list(content) ->
          comments =
            content
            |> Enum.reject(&(&1["deleted"] == true))
            |> Enum.map(&normalize_comment/1)

          {:ok, comments}

        {:ok, %{status: 404}} ->
          {:ok, []}

        {:ok, %{status: status}} ->
          Logger.error("YouGile fetch_comments failed status=#{status}")
          {:error, {:yougile_api_status, status}}

        {:error, reason} ->
          {:error, {:yougile_api_request, reason}}
      end
    end
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(task_id, body, opts \\ []) when is_binary(task_id) and is_binary(body) do
    with {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/chats/#{task_id}/messages"

      message_body = %{
        "text" => body,
        "textHtml" => "<p>#{html_escape(body)}</p>",
        "label" => ""
      }

      case request_fun.(%{method: :post, url: url, token: token, body: message_body}) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: status}} ->
          Logger.error("YouGile create_comment failed status=#{status}")
          {:error, {:yougile_api_status, status}}

        {:error, reason} ->
          {:error, {:yougile_api_request, reason}}
      end
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(task_id, state_name, opts \\ [])
      when is_binary(task_id) and is_binary(state_name) do
    with {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      target_column_id = YouGile.Config.column_id(state_name)

      if is_nil(target_column_id) do
        {:error, {:unknown_state, state_name}}
      else
        do_update_task_column(request_fun, token, task_id, target_column_id, state_name)
      end
    end
  end

  # -- Private helpers --------------------------------------------------------

  defp do_fetch_issues_by_states(state_names, opts) do
    with {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      columns = YouGile.Config.columns()

      column_ids =
        state_names
        |> Enum.map(&Map.get(columns, normalize_state(&1)))
        |> Enum.filter(&is_binary/1)

      fetch_tasks_for_columns(column_ids, request_fun, token, columns)
    end
  end

  defp do_fetch_issue_states_by_ids(issue_ids, opts) do
    with {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      columns = YouGile.Config.columns()

      result =
        Enum.reduce_while(issue_ids, {:ok, []}, fn task_id, {:ok, acc} ->
          url = "#{@base_url}/tasks/#{task_id}"

          case request_fun.(%{method: :get, url: url, token: token}) do
            {:ok, %{status: 200, body: body}} when is_map(body) ->
              {:cont, {:ok, [normalize_task(body, columns, request_fun) | acc]}}

            {:ok, %{status: 404}} ->
              {:cont, {:ok, acc}}

            {:ok, %{status: status}} ->
              {:halt, {:error, {:yougile_api_status, status}}}

            {:error, reason} ->
              {:halt, {:error, {:yougile_api_request, reason}}}
          end
        end)

      case result do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        error -> error
      end
    end
  end

  defp fetch_tasks_for_columns(column_ids, request_fun, token, columns) do
    result =
      Enum.reduce_while(column_ids, {:ok, %{}}, fn column_id, {:ok, acc} ->
        case fetch_all_tasks_in_column(request_fun, token, column_id, columns) do
          {:ok, tasks} ->
            merged = Map.merge(acc, Map.new(tasks, &{&1.id, &1}), fn _k, v, _new -> v end)
            {:cont, {:ok, merged}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, map} -> {:ok, filter_by_role(Map.values(map))}
      error -> error
    end
  end

  defp filter_by_role(issues) do
    if YouGile.Config.role_sticker_id() do
      Enum.filter(issues, fn issue -> issue.role != nil end)
    else
      issues
    end
  end

  defp fetch_all_tasks_in_column(request_fun, token, column_id, columns) do
    fetch_all_tasks_in_column(request_fun, token, column_id, columns, 0, [])
  end

  defp fetch_all_tasks_in_column(request_fun, token, column_id, columns, offset, acc) do
    url = "#{@base_url}/task-list?columnId=#{column_id}&limit=#{@per_page}&offset=#{offset}"

    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: %{"content" => content, "paging" => paging}}} when is_list(content) ->
        tasks = Enum.map(content, &normalize_task(&1, columns, request_fun))
        all = acc ++ tasks

        if paging["next"] == true do
          fetch_all_tasks_in_column(request_fun, token, column_id, columns, offset + @per_page, all)
        else
          {:ok, all}
        end

      {:ok, %{status: 200, body: %{"content" => content}}} when is_list(content) ->
        {:ok, acc ++ Enum.map(content, &normalize_task(&1, columns, request_fun))}

      {:ok, %{status: status}} ->
        Logger.error("YouGile API request failed status=#{status}")
        {:error, {:yougile_api_status, status}}

      {:error, reason} ->
        Logger.error("YouGile API request failed: #{inspect(reason)}")
        {:error, {:yougile_api_request, reason}}
    end
  end

  defp do_update_task_column(request_fun, token, task_id, column_id, state_name) do
    url = "#{@base_url}/tasks/#{task_id}"

    body =
      %{"columnId" => column_id}
      |> maybe_mark_completed(state_name)

    case request_fun.(%{method: :put, url: url, token: token, body: body}) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status}} ->
        Logger.error("YouGile update_issue_state failed status=#{status}")
        {:error, {:yougile_api_status, status}}

      {:error, reason} ->
        {:error, {:yougile_api_request, reason}}
    end
  end

  defp maybe_mark_completed(body, state_name) do
    if normalize_state(state_name) in ["done", "cancelled"] do
      Map.put(body, "completed", true)
    else
      body
    end
  end

  defp normalize_task(task, columns, request_fun) when is_map(task) do
    task_id = task["id"]
    column_id = task["columnId"]
    stickers = task["stickers"] || %{}

    %Issue{
      id: task_id,
      identifier: task["idTaskProject"] || task["idTaskCommon"] || task_id,
      title: task["title"],
      description: task["description"],
      priority: extract_priority(stickers),
      role: extract_role(stickers, request_fun),
      state: state_for_column_id(column_id, columns),
      branch_name: nil,
      url: nil,
      assignee_id: extract_assignee(task["assigned"]),
      labels: [],
      assigned_to_worker: true,
      created_at: parse_timestamp(task["timestamp"]),
      updated_at: nil
    }
  end

  defp state_for_column_id(nil, _columns), do: nil

  defp state_for_column_id(column_id, columns) do
    Enum.find_value(columns, fn {state, cid} ->
      if cid == column_id, do: state
    end)
  end

  defp extract_priority(stickers) when map_size(stickers) == 0, do: nil

  defp extract_priority(stickers) do
    case YouGile.Config.priority_sticker_id() do
      nil ->
        nil

      sticker_id ->
        case Map.get(stickers, sticker_id) do
          nil -> nil
          "empty" -> nil
          "-" -> nil
          value -> parse_priority_value(value)
        end
    end
  end

  defp normalize_comment(message) when is_map(message) do
    %{
      text: message["text"] || "",
      from_user_id: message["fromUserId"],
      created_at: parse_timestamp(message["id"])
    }
  end

  defp extract_role(stickers, _request_fun) when map_size(stickers) == 0, do: nil

  defp extract_role(stickers, request_fun) do
    case YouGile.Config.role_sticker_id() do
      nil -> nil

      sticker_id ->
        case Map.get(stickers, sticker_id) do
          nil -> nil
          "empty" -> nil
          "-" -> nil
          state_id when is_binary(state_id) ->
            resolve_sticker_state_name(sticker_id, state_id, request_fun)
          _ -> nil
        end
    end
  end

  defp resolve_sticker_state_name(sticker_id, state_id, request_fun) do
    states_map = get_or_fetch_sticker_states(sticker_id, request_fun)
    Map.get(states_map, state_id, state_id)
  end

  defp get_or_fetch_sticker_states(sticker_id, request_fun) do
    cache_key = {:yougile_sticker_states, sticker_id}

    case Process.get(cache_key) do
      nil ->
        states_map = fetch_sticker_states(sticker_id, request_fun)
        Process.put(cache_key, states_map)
        states_map

      cached ->
        cached
    end
  end

  defp fetch_sticker_states(sticker_id, request_fun) do
    with {:ok, token} <- require_token() do
      case request_fun.(%{
             method: :get,
             url: "#{@base_url}/string-stickers/#{sticker_id}",
             token: token
           }) do
        {:ok, %{status: 200, body: %{"states" => states}}} when is_list(states) ->
          Map.new(states, fn %{"id" => id, "name" => name} -> {id, name} end)

        other ->
          Logger.warning("Failed to fetch sticker states for #{sticker_id}: #{inspect(other)}")
          %{}
      end
    else
      _ -> %{}
    end
  end

  defp parse_priority_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {priority, _} -> priority
      :error -> nil
    end
  end

  defp parse_priority_value(_), do: nil

  defp extract_assignee(assigned) when is_list(assigned) and length(assigned) > 0 do
    List.first(assigned)
  end

  defp extract_assignee(_), do: nil

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_number(ts) do
    case DateTime.from_unix(trunc(ts), :millisecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp normalize_state(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp require_token do
    case YouGile.Config.token() do
      nil -> {:error, :missing_yougile_token}
      token -> {:ok, token}
    end
  end

  defp default_request_fun(%{method: :get, url: url, token: token}) do
    Req.get(url, headers: yougile_headers(token), connect_options: [timeout: 30_000])
  end

  defp default_request_fun(%{method: :post, url: url, token: token, body: body}) do
    Req.post(url, headers: yougile_headers(token), json: body, connect_options: [timeout: 30_000])
  end

  defp default_request_fun(%{method: :put, url: url, token: token, body: body}) do
    Req.put(url, headers: yougile_headers(token), json: body, connect_options: [timeout: 30_000])
  end

  defp yougile_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]
  end
end
