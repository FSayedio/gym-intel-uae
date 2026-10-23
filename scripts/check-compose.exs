config = :stdio |> IO.read(:eof) |> Jason.decode!()
services = config["services"]

unless Enum.sort(Map.keys(services)) == ["app", "grafana", "postgres"],
  do: raise("Expected exactly the three application services")

for {_name, service} <- services do
  unless service["platform"] == "linux/arm64", do: raise("ARM64 support changed")
end

for {name, target, expected} <- [
      {"postgres", 5432, System.fetch_env!("EXPECTED_POSTGRES_HOST_PORT")},
      {"grafana", 3000, System.fetch_env!("EXPECTED_GRAFANA_HOST_PORT")}
    ] do
  [port] = services[name]["ports"]

  unless port["host_ip"] == "127.0.0.1" and port["target"] == target and
           to_string(port["published"]) == expected,
         do: raise("Unexpected host/internal binding for #{name}")
end

unless services["app"]["build"]["target"] == "runtime",
  do: raise("Default app must use the runtime target")

unless services["app"]["environment"]["DATABASE_HOST"] == "postgres" and
         to_string(services["app"]["environment"]["DATABASE_PORT"]) == "5432",
       do: raise("Host-port changes must not change the app's internal DB endpoint")

secrets = Enum.map(services["app"]["secrets"], & &1["source"])
unless secrets == ["postgres_app_password"], do: raise("Unexpected app credential mounts")

unless Enum.sort(Map.keys(config["volumes"])) == ["grafana_data", "postgres_data"],
  do: raise("Persistent volume definitions changed")

binds = Enum.filter(services["postgres"]["volumes"], &(&1["type"] == "bind"))

unless Enum.sort(Enum.map(binds, & &1["target"])) == ["/opt/gym-intel", "/opt/gym-intel-priv"] and
         Enum.all?(binds, & &1["read_only"]),
       do: raise("PostgreSQL configuration must use the two read-only directory mounts")

unless services["postgres"]["command"] == [
         "postgres",
         "-c",
         "hba_file=/opt/gym-intel/pg_hba.conf"
       ],
       do: raise("PostgreSQL must read authentication rules from the mounted directory")

IO.puts(
  "PASS: three ARM64 services, runtime target, private host ports, stable internal DB and volumes"
)
