defmodule SymphonyElixir.YouGile.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.YouGile.Client
  alias SymphonyElixir.Workflow

  @col_todo "col-todo-uuid"
  @col_in_progress "col-ip-uuid"
  @col_done "col-done-uuid"
  @col_cancelled "col-cancelled-uuid"
  @priority_sticker "sticker-priority-uuid"

  setup do
    prev_token = System.get_env("YOUGILE_TOKEN")
    System.put_env("YOUGILE_TOKEN", "test-yougile-token")

    on_exit(fn ->
      restore_env("YOUGILE_TOKEN", prev_token)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "yougile",
      tracker_board_id: "board-uuid",
      tracker_columns: %{
        "todo" => @col_todo,
        "in-progress" => @col_in_progress,
        "done" => @col_done,
        "cancelled" => @col_cancelled
      },
      tracker_priority_sticker_id: @priority_sticker
    )

    :ok
  end

  defp task_response(attrs) do
    Map.merge(
      %{
        "id" => "task-1",
        "title" => "Fix the bug",
        "description" => "Something is broken",
        "columnId" => @col_todo,
        "timestamp" => 1_623_223_299_149,
        "completed" => false,
        "assigned" => ["user-1"],
        "stickers" => %{@priority_sticker => "1"},
        "idTaskProject" => "DEV-42",
        "idTaskCommon" => "ID-42"
      },
      attrs
    )
  end

  describe "fetch_candidate_issues/1" do
    test "returns normalized issues from YouGile API" do
      request_fun = fn %{method: :get, url: url, token: token} ->
        assert token == "test-yougile-token"
        assert url =~ "/task-list"

        if url =~ @col_todo do
          {:ok,
           %{
             status: 200,
             body: %{
               "content" => [task_response(%{})],
               "paging" => %{"count" => 1, "limit" => 100, "offset" => 0, "next" => false}
             }
           }}
        else
          {:ok,
           %{
             status: 200,
             body: %{
               "content" => [],
               "paging" => %{"count" => 0, "limit" => 100, "offset" => 0, "next" => false}
             }
           }}
        end
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.id == "task-1"
      assert issue.identifier == "DEV-42"
      assert issue.title == "Fix the bug"
      assert issue.description == "Something is broken"
      assert issue.state == "todo"
      assert issue.priority == 1
      assert issue.assignee_id == "user-1"
    end

    test "deduplicates issues across columns" do
      request_fun = fn %{method: :get} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [task_response(%{"id" => "task-dup"})],
             "paging" => %{"count" => 1, "limit" => 100, "offset" => 0, "next" => false}
           }
         }}
      end

      assert {:ok, [_single]} = Client.fetch_candidate_issues(request_fun: request_fun)
    end

    test "returns error on API failure" do
      request_fun = fn _ ->
        {:ok, %{status: 401}}
      end

      assert {:error, {:yougile_api_status, 401}} =
               Client.fetch_candidate_issues(request_fun: request_fun)
    end

    test "returns error when token is missing" do
      System.delete_env("YOUGILE_TOKEN")
      assert {:error, :missing_yougile_token} = Client.fetch_candidate_issues()
    end

    test "handles pagination" do
      call_count = :counters.new(1, [:atomics])

      request_fun = fn %{method: :get, url: url} ->
        :counters.add(call_count, 1, 1)

        if url =~ "offset=0" do
          {:ok,
           %{
             status: 200,
             body: %{
               "content" => [task_response(%{"id" => "task-page1"})],
               "paging" => %{"count" => 1, "limit" => 100, "offset" => 0, "next" => true}
             }
           }}
        else
          {:ok,
           %{
             status: 200,
             body: %{
               "content" => [task_response(%{"id" => "task-page2"})],
               "paging" => %{"count" => 1, "limit" => 100, "offset" => 100, "next" => false}
             }
           }}
        end
      end

      assert {:ok, issues} = Client.fetch_candidate_issues(request_fun: request_fun)
      ids = Enum.map(issues, & &1.id)
      assert "task-page1" in ids
      assert "task-page2" in ids
    end
  end

  describe "fetch_issues_by_states/2" do
    test "returns empty list for empty states" do
      assert {:ok, []} = Client.fetch_issues_by_states([])
    end

    test "fetches issues by column for given states" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "columnId=#{@col_todo}"

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [task_response(%{})],
             "paging" => %{"count" => 1, "limit" => 100, "offset" => 0, "next" => false}
           }
         }}
      end

      assert {:ok, issues} = Client.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert length(issues) == 1
      assert hd(issues).id == "task-1"
      assert hd(issues).state == "todo"
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty ids" do
      assert {:ok, []} = Client.fetch_issue_states_by_ids([])
    end

    test "fetches individual tasks by id" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/tasks/task-42"

        {:ok,
         %{
           status: 200,
           body: task_response(%{"id" => "task-42", "columnId" => @col_in_progress})
         }}
      end

      assert {:ok, [issue]} =
               Client.fetch_issue_states_by_ids(["task-42"], request_fun: request_fun)

      assert issue.id == "task-42"
      assert issue.state == "in-progress"
    end

    test "skips 404 tasks" do
      request_fun = fn _ ->
        {:ok, %{status: 404}}
      end

      assert {:ok, []} = Client.fetch_issue_states_by_ids(["missing"], request_fun: request_fun)
    end
  end

  describe "create_comment/3" do
    test "sends a message to the task chat" do
      request_fun = fn %{method: :post, url: url, body: body} ->
        assert url =~ "/chats/task-42/messages"
        assert body["text"] == "Hello!"
        assert body["textHtml"] =~ "Hello!"
        {:ok, %{status: 201}}
      end

      assert :ok = Client.create_comment("task-42", "Hello!", request_fun: request_fun)
    end

    test "returns error on failure" do
      request_fun = fn _ -> {:ok, %{status: 403}} end

      assert {:error, {:yougile_api_status, 403}} =
               Client.create_comment("task-42", "Hello!", request_fun: request_fun)
    end
  end

  describe "update_issue_state/3" do
    test "moves task to target column" do
      request_fun = fn %{method: :put, url: url, body: body} ->
        assert url =~ "/tasks/task-42"
        assert body["columnId"] == @col_in_progress
        refute Map.has_key?(body, "completed")
        {:ok, %{status: 200}}
      end

      assert :ok = Client.update_issue_state("task-42", "in-progress", request_fun: request_fun)
    end

    test "marks task as completed for terminal states" do
      request_fun = fn %{method: :put, body: body} ->
        assert body["columnId"] == @col_done
        assert body["completed"] == true
        {:ok, %{status: 200}}
      end

      assert :ok = Client.update_issue_state("task-42", "Done", request_fun: request_fun)
    end

    test "returns error for unknown state" do
      assert {:error, {:unknown_state, "nonexistent"}} =
               Client.update_issue_state("task-42", "nonexistent", request_fun: fn _ -> :unused end)
    end

    test "returns error on API failure" do
      request_fun = fn _ -> {:ok, %{status: 500}} end

      assert {:error, {:yougile_api_status, 500}} =
               Client.update_issue_state("task-42", "todo", request_fun: request_fun)
    end
  end

  describe "priority extraction" do
    test "extracts priority from sticker" do
      request_fun = fn %{method: :get} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [
               task_response(%{"stickers" => %{@priority_sticker => "3"}})
             ],
             "paging" => %{"count" => 1, "limit" => 100, "offset" => 0, "next" => false}
           }
         }}
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.priority == 3
    end

    test "returns nil priority when sticker is missing" do
      request_fun = fn %{method: :get} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [
               task_response(%{"stickers" => %{}})
             ],
             "paging" => %{"count" => 1, "limit" => 100, "offset" => 0, "next" => false}
           }
         }}
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.priority == nil
    end
  end
end
