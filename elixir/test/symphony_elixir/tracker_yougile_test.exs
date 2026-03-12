defmodule SymphonyElixir.YouGile.TrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.YouGile.Tracker, as: YouGileTracker
  alias SymphonyElixir.Workflow

  defmodule MockYouGileClient do
    alias SymphonyElixir.Issue

    def fetch_candidate_issues, do: {:ok, [%Issue{id: "task-1", identifier: "DEV-1", title: "Test"}]}
    def fetch_issues_by_states(states), do: {:ok, Enum.map(states, fn _ -> %Issue{id: "task-1"} end)}
    def fetch_issue_states_by_ids(ids), do: {:ok, Enum.map(ids, fn id -> %Issue{id: id} end)}
    def create_comment(_id, _body), do: :ok
    def update_issue_state(_id, _state), do: :ok
  end

  setup do
    prev_token = System.get_env("YOUGILE_TOKEN")
    System.put_env("YOUGILE_TOKEN", "test-yougile-token")

    Application.put_env(:symphony_elixir, :yougile_client_module, MockYouGileClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "yougile",
      tracker_board_id: "board-uuid",
      tracker_columns: %{
        "todo" => "col-todo-uuid",
        "in-progress" => "col-ip-uuid",
        "done" => "col-done-uuid",
        "cancelled" => "col-cancelled-uuid"
      }
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :yougile_client_module)
      restore_env("YOUGILE_TOKEN", prev_token)
    end)

    :ok
  end

  test "implements Tracker behaviour" do
    assert {:ok, _issues} = YouGileTracker.fetch_candidate_issues()
  end

  test "fetch_issues_by_states delegates to client" do
    assert {:ok, issues} = YouGileTracker.fetch_issues_by_states(["todo"])
    assert length(issues) == 1
  end

  test "fetch_issue_states_by_ids delegates to client" do
    assert {:ok, [issue]} = YouGileTracker.fetch_issue_states_by_ids(["task-42"])
    assert issue.id == "task-42"
  end

  test "create_comment delegates to client" do
    assert :ok = YouGileTracker.create_comment("task-42", "comment body")
  end

  test "update_issue_state delegates to client" do
    assert :ok = YouGileTracker.update_issue_state("task-42", "Done")
  end

  test "tracker routes to YouGile adapter when kind is yougile" do
    assert Tracker.adapter() == SymphonyElixir.YouGile.Tracker
  end
end
