defmodule GymIntel.ImportConcurrencyDatabaseTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias GymIntel.{Membership, MembershipCSV, MembershipImporter, Repo}
  @moduletag :database

  defp csv(brand, note) do
    Enum.join(MembershipCSV.headers(), ",") <>
      "\n#{brand},,TEST ONLY,all_uae_branches,,199,1,,,https://example.com/concurrency,,2026-10-22,#{note},,,,\n"
  end

  defp fixture do
    brand = "TEST CONCURRENT #{System.unique_integer([:positive])}"
    original = csv(brand, "First note")
    changed = csv(brand, "Second note")
    unrelated = csv(brand <> " OTHER", "Other note")

    hashes =
      Enum.map(
        [original, changed, unrelated],
        &(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))
      )

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids =
          Repo.all(
            from(m in Membership,
              where: m.brand_name in ^[brand, brand <> " OTHER"],
              select: m.id
            )
          )

        Repo.delete_all(from(n in "membership_notes", where: n.membership_id in ^ids))
        Repo.delete_all(from(m in Membership, where: m.id in ^ids))
        Repo.delete_all(from(i in "membership_imports", where: i.content_sha256 in ^hashes))
      end)
    end)

    {brand, original, changed, unrelated}
  end

  defp held_import(contents, parent) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(fn ->
          result = MembershipImporter.import_csv(contents)
          send(parent, {:first_inserted, self()})

          receive do
            :commit -> result
          after
            5_000 -> raise "Test did not release the held transaction"
          end
        end)
      end)
    end)
  end

  defp wait_for_lock(pid, attempts \\ 100)
  defp wait_for_lock(_pid, 0), do: false

  defp wait_for_lock(pid, attempts) do
    locked? =
      Sandbox.unboxed_run(Repo, fn ->
        case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1", [pid]).rows do
          [["Lock"]] -> true
          _ -> false
        end
      end)

    if locked?,
      do: true,
      else:
        (
          Process.sleep(10)
          wait_for_lock(pid, attempts - 1)
        )
  end

  test "a genuinely overlapping import waits for uniqueness then preserves both note versions" do
    {brand, original, changed, _} = fixture()
    parent = self()
    first = held_import(original, parent)
    assert_receive {:first_inserted, first_pid}, 3_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:second_backend, pid})
          MembershipImporter.import_csv(changed)
        end)
      end)

    try do
      assert_receive {:second_backend, pid}, 3_000
      assert wait_for_lock(pid), "second import never reached a database lock wait"
    after
      send(first_pid, :commit)
    end

    assert {:ok, {:ok, {:imported, %{inserted: 1, notes_added: 1}}}} = Task.await(first)
    assert {:ok, {:imported, %{inserted: 0, skipped: 1, notes_added: 1}}} = Task.await(second)

    Sandbox.unboxed_run(Repo, fn ->
      assert [row] = Repo.all(from(m in Membership, where: m.brand_name == ^brand))

      assert %{rows: [[2]]} =
               Repo.query!("SELECT count(*) FROM membership_notes WHERE membership_id=$1", [
                 row.id
               ])
    end)
  end

  test "an unrelated writer completes before the held import commits; no whole-table lock" do
    {_brand, original, _changed, unrelated} = fixture()
    first = held_import(original, self())
    assert_receive {:first_inserted, first_pid}, 3_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> MembershipImporter.import_csv(unrelated) end)
      end)

    result =
      try do
        Task.yield(second, 2_000)
      after
        send(first_pid, :commit)
      end

    assert {:ok, {:ok, {:imported, %{inserted: 1}}}} = result
    assert {:ok, {:ok, {:imported, _}}} = Task.await(first)
  end

  test "concurrent identical files commit once and return already_imported for the retry" do
    {_brand, original, _, _} = fixture()
    first = held_import(original, self())
    assert_receive {:first_inserted, first_pid}, 3_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> MembershipImporter.import_csv(original) end)
      end)

    send(first_pid, :commit)
    assert {:ok, {:ok, {:imported, _}}} = Task.await(first)
    assert {:ok, :already_imported} = Task.await(second)
  end
end
