defmodule GymIntel.MembershipImporterTest do
  use ExUnit.Case, async: true

  alias GymIntel.{MembershipCSV, MembershipImporter}

  # These paths must return before accessing Repo; tests run with --no-start.
  test "rejects an invalid header without accessing the database" do
    assert {:error, :header_mismatch} = MembershipImporter.import_csv("wrong\n")
  end

  test "header-only CSV is a no-op without accessing the database" do
    header = Enum.join(MembershipCSV.headers(), ",") <> "\n"
    assert {:ok, :empty} = MembershipImporter.import_csv(header)
  end

  test "missing files return an error without accessing the database" do
    assert {:error, {:file, :enoent}} =
             MembershipImporter.import_file("data/nonexistent-test-input.csv")
  end

  @tag :tmp_dir
  test "oversized input is rejected by both importer entrypoints before database access", %{
    tmp_dir: dir
  } do
    contents = String.duplicate("x", MembershipCSV.max_bytes() + 1)
    path = Path.join(dir, "oversized.csv")
    File.write!(path, contents)
    assert {:error, :csv_too_large} = MembershipImporter.import_file(path)
    assert {:error, :csv_too_large} = MembershipImporter.import_csv(contents)
  end
end
