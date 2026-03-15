defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in an isolated workspace with the configured coding agent.
  """

  require Logger
  alias SymphonyElixir.{CodingAgent, Config, Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, codex_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, codex_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _codex_update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        result =
          try do
            with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          after
            Workspace.run_after_run_hook(workspace, issue, worker_host)
          end

        if result == :ok do
          post_summary_comment(workspace, issue)
          move_to_review(issue)
        end

        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      normalized = CodingAgent.normalize_event(message)
      send_codex_update(recipient, issue, normalized)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp post_summary_comment(workspace, issue) do
    if Config.tracker_kind() == "yougile" do
      summary_path = Path.join(workspace, "#{issue.identifier}.md")

      case File.read(summary_path) do
        {:ok, content} when byte_size(content) > 0 ->
          case Tracker.create_comment(issue.id, String.trim(content)) do
            :ok ->
              Logger.info("Posted summary comment for #{issue_context(issue)} from #{summary_path}")

            {:error, reason} ->
              Logger.warning("Failed to post summary comment for #{issue_context(issue)}: #{inspect(reason)}")
          end

        {:ok, _empty} ->
          Logger.info("Summary file is empty for #{issue_context(issue)}, skipping comment")

        {:error, :enoent} ->
          Logger.info("No summary file found at #{summary_path} for #{issue_context(issue)}, skipping comment")

        {:error, reason} ->
          Logger.warning("Failed to read summary file for #{issue_context(issue)}: #{inspect(reason)}")
      end
    end
  end

  defp cleanup_summary_file(workspace, issue) do
    if Config.tracker_kind() == "yougile" do
      path = Path.join(workspace, "#{issue.identifier}.md")

      if File.exists?(path) do
        File.rm(path)
        Logger.info("Removed previous summary file #{path} for #{issue_context(issue)}")
      end
    end
  end

  defp summary_file_exists?(workspace, issue) do
    Config.tracker_kind() == "yougile" and
      File.exists?(Path.join(workspace, "#{issue.identifier}.md"))
  end

  defp move_to_review(issue) do
    if Config.tracker_kind() == "yougile" do
      case Tracker.update_issue_state(issue.id, "in-review") do
        :ok ->
          Logger.info("Moved #{issue_context(issue)} to in-review after agent completion")

        {:error, reason} ->
          Logger.warning("Failed to move #{issue_context(issue)} to in-review: #{inspect(reason)}")
      end
    end
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    cleanup_summary_file(workspace, issue)

    with {:ok, session} <- CodingAgent.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        CodingAgent.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           CodingAgent.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          if summary_file_exists?(workspace, refreshed_issue) do
            Logger.info("Summary file found for #{issue_context(refreshed_issue)}, agent work complete turn=#{turn_number}/#{max_turns}")
            :ok
          else
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
            )
          end

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    issue = enrich_with_comments(issue)
    PromptBuilder.build_prompt(issue, opts)
  end

  defp build_turn_prompt(issue, opts, turn_number, max_turns) do
    issue = enrich_with_comments(issue)
    original_prompt = PromptBuilder.build_prompt(issue, opts)

    """
    Continuation guidance:

    - The previous turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace state instead of restarting from scratch.
    - Review what has already been done (check git log, existing files) and focus on completing the remaining steps.
    - Do not end the turn while there is still unfinished work from the original instructions.

    Original task instructions (for reference):

    #{original_prompt}
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp enrich_with_comments(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    case Tracker.fetch_comments(issue_id) do
      {:ok, comments} ->
        %{issue | comments: comments}

      {:error, reason} ->
        Logger.warning("Failed to fetch comments for #{issue_context(issue)}: #{inspect(reason)}")
        issue
    end
  end

  defp enrich_with_comments(issue), do: issue

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
