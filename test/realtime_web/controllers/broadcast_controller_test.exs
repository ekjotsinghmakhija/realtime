defmodule RealtimeWeb.BroadcastControllerTest do
  # async: false due to usage of mocks
  use RealtimeWeb.ConnCase, async: false

  import Mock

  alias Realtime.Crypto
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Database

  alias RealtimeWeb.Endpoint

  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE1MTYyMzkwMjIsInJvbGUiOiJmb28iLCJleHAiOiJiYXIifQ.Ret2CevUozCsPhpgW2FMeFL7RooLgoOvfQzNpLBj5ak"
  @expired_token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MjEwNzMyOTAsImlhdCI6MTYyNzg4NjQ0MCwicm9sZSI6ImFub24ifQ.AHmuaydSU3XAxwoIFhd3gwGwjnBIKsjFil0JQEOLtRw"

  setup %{conn: conn} do
    start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
    start_supervised(Realtime.RateCounter.DynamicSupervisor)
    start_supervised(Realtime.GenCounter.DynamicSupervisor)

    tenant = Containers.checkout_tenant(run_migrations: true)

    conn = generate_conn(conn, tenant)

    {:ok, conn: conn, tenant: tenant}
  end

  describe "broadcast" do
    test "returns 202 when batch of messages is broadcasted", %{conn: conn, tenant: tenant} do
      events_key = Tenants.events_per_second_key(tenant)

      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end}
      ] do
        sub_topic_1 = "sub_topic_1"
        sub_topic_2 = "sub_topic_2"
        topic_1 = Tenants.tenant_topic(tenant, sub_topic_1)
        topic_2 = Tenants.tenant_topic(tenant, sub_topic_2)

        payload_1 = %{"data" => "data"}
        payload_2 = %{"data" => "data"}
        event_1 = "event_1"
        event_2 = "event_2"

        conn =
          post(conn, Routes.broadcast_path(conn, :broadcast), %{
            "messages" => [
              %{"topic" => sub_topic_1, "payload" => payload_1, "event" => event_1},
              %{"topic" => sub_topic_1, "payload" => payload_1, "event" => event_1},
              %{"topic" => sub_topic_2, "payload" => payload_2, "event" => event_2}
            ]
          })

        assert_called_exactly(
          Endpoint.broadcast_from(:_, topic_1, "broadcast", %{
            "payload" => payload_1,
            "event" => event_1,
            "type" => "broadcast"
          }),
          2
        )

        assert_called(
          Endpoint.broadcast_from(:_, topic_2, "broadcast", %{
            "payload" => payload_2,
            "event" => event_2,
            "type" => "broadcast"
          })
        )

        assert_called_exactly(GenCounter.add(events_key), 3)
        assert conn.status == 202
      end
    end

    test "returns 422 when batch of messages includes badly formed messages", %{
      conn: conn,
      tenant: tenant
    } do
      with_mock Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end do
        conn =
          post(conn, Routes.broadcast_path(conn, :broadcast), %{
            "messages" => [
              %{
                "topic" => "topic"
              },
              %{
                "payload" => %{"data" => "data"}
              },
              %{
                "topic" => "topic",
                "payload" => %{"data" => "data"},
                "event" => "event"
              }
            ]
          })

        assert Jason.decode!(conn.resp_body) == %{
                 "errors" => %{
                   "messages" => [
                     %{"payload" => ["can't be blank"], "event" => ["can't be blank"]},
                     %{"topic" => ["can't be blank"], "event" => ["can't be blank"]},
                     %{}
                   ]
                 }
               }

        assert_not_called(Endpoint.broadcast_from(:_, :_, :_, :_))

        assert conn.status == 422

        # Wait for counters to increment
        Process.sleep(1000)
        {:ok, rate_counter} = RateCounter.get(Tenants.requests_per_second_key(tenant))
        assert rate_counter.avg != 0.0

        {:ok, rate_counter} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert rate_counter.avg == 0.0
      end
    end
  end

  describe "too many requests" do
    test "batch will exceed rate limit", %{conn: conn, tenant: tenant} do
      requests_key = Tenants.requests_per_second_key(tenant)
      events_key = Tenants.events_per_second_key(tenant)

      with_mocks [
        {RateCounter, [], new: fn _, _ -> {:ok, nil} end},
        {RateCounter, [],
         get: fn
           ^requests_key -> {:ok, %RateCounter{avg: 0}}
           ^events_key -> {:ok, %RateCounter{avg: 10}}
         end}
      ] do
        conn =
          post(conn, Routes.broadcast_path(conn, :broadcast), %{
            "messages" =>
              Stream.repeatedly(fn ->
                %{
                  "topic" => Tenants.tenant_topic(tenant, "sub_topic"),
                  "payload" => %{"data" => "data"},
                  "event" => "event"
                }
              end)
              |> Enum.take(1000)
          })

        assert conn.status == 429

        assert conn.resp_body ==
                 Jason.encode!(%{
                   message: "Too many messages to broadcast, please reduce the batch size"
                 })
      end
    end

    test "user has hit the rate limit", %{conn: conn, tenant: tenant} do
      requests_key = Tenants.requests_per_second_key(tenant)
      events_key = Tenants.events_per_second_key(tenant)

      with_mocks [
        {RateCounter, [], new: fn _, _ -> {:ok, nil} end},
        {RateCounter, [],
         get: fn
           ^requests_key -> {:ok, %RateCounter{avg: 0}}
           ^events_key -> {:ok, %RateCounter{avg: 1000}}
         end}
      ] do
        messages = [
          %{"topic" => Tenants.tenant_topic(tenant, "sub_topic"), "payload" => %{"data" => "data"}, "event" => "event"}
        ]

        conn = generate_conn(conn, tenant)
        conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{"messages" => messages})
        assert conn.status == 429
        assert conn.resp_body == Jason.encode!(%{message: "You have exceeded your rate limit"})
      end
    end
  end

  describe "unauthorized" do
    test "invalid token returns 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("x-api-key", "potato")
        |> then(&%{&1 | host: "dev_tenant.tealbase.com"})

      conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{})
      assert conn.status == 401
    end

    test "expired token returns 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("x-api-key", @expired_token)
        |> then(&%{&1 | host: "dev_tenant.tealbase.com"})

      conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{})
      assert conn.status == 401
    end

    test "invalid tenant returns 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("x-api-key", "potato")
        |> then(&%{&1 | host: "potato.tealbase.com"})

      conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{})
      assert conn.status == 401
    end
  end

  describe "authorization for broadcast" do
    setup %{conn: conn, tenant: tenant} = context do
      start_supervised(Realtime.RateCounter.DynamicSupervisor)
      start_supervised(Realtime.GenCounter.DynamicSupervisor)
      start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)

      jwt_secret = Crypto.decrypt!(tenant.jwt_secret)

      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      clean_table(db_conn, "realtime", "messages")

      claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
      signer = Joken.Signer.create("HS256", jwt_secret)

      jwt = Joken.generate_and_sign!(%{}, claims, signer)

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> then(&%{&1 | host: "#{tenant.external_id}.tealbase.com"})

      {:ok, conn: conn, db_conn: db_conn, tenant: tenant}
    end

    @tag role: "authenticated"
    test "user with permission to read all channels and write to them is able to broadcast", %{
      conn: conn,
      db_conn: db_conn,
      tenant: tenant
    } do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end}
      ] do
        messages_to_send =
          Stream.repeatedly(fn -> generate_message_with_policies(db_conn, tenant) end)
          |> Enum.take(5)

        messages =
          Enum.map(messages_to_send, fn %{topic: topic} ->
            %{
              "topic" => topic,
              "payload" => %{"content" => random_string()},
              "event" => random_string(),
              "private" => true
            }
          end)

        conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{"messages" => messages})

        Enum.each(messages_to_send, fn %{topic: topic} ->
          topic = Tenants.tenant_topic(tenant, topic, false)
          assert_called(Endpoint.broadcast_from(:_, topic, "broadcast", :_))
        end)

        assert_called_exactly(
          GenCounter.add(Tenants.events_per_second_key(tenant)),
          length(messages)
        )

        assert conn.status == 202
      end
    end

    @tag role: "authenticated"
    test "user with permission is also able to broadcast to open channel", %{
      conn: conn,
      db_conn: db_conn,
      tenant: tenant
    } do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end}
      ] do
        channels =
          Stream.repeatedly(fn -> generate_message_with_policies(db_conn, tenant) end)
          |> Enum.take(5)

        messages =
          Enum.map(channels, fn %{topic: topic} ->
            %{
              "topic" => topic,
              "payload" => %{"content" => random_string()},
              "event" => random_string(),
              "private" => true
            }
          end)

        messages =
          messages ++
            [%{"topic" => "open_channel", "payload" => %{"content" => random_string()}, "event" => random_string()}]

        conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{"messages" => messages})

        Enum.each(channels, fn %{topic: topic} ->
          topic = Tenants.tenant_topic(tenant, topic, topic == "open_channel")
          assert_called(Endpoint.broadcast_from(:_, topic, "broadcast", :_))
        end)

        # Check open channel
        assert_called(Endpoint.broadcast_from(:_, Tenants.tenant_topic(tenant, "open_channel"), "broadcast", :_))
        assert_called_exactly(GenCounter.add(Tenants.events_per_second_key(tenant)), length(channels) + 1)

        assert conn.status == 202
      end
    end

    @tag role: "authenticated"
    test "user with permission to write a limited set is only able to broadcast to said set", %{
      conn: conn,
      db_conn: db_conn,
      tenant: tenant
    } do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end}
      ] do
        messages_to_send =
          Stream.repeatedly(fn -> generate_message_with_policies(db_conn, tenant) end)
          |> Enum.take(5)

        no_auth_channel = message_fixture(tenant)

        messages =
          Enum.map(messages_to_send ++ [no_auth_channel], fn %{topic: topic} ->
            %{
              "topic" => topic,
              "payload" => %{"content" => random_string()},
              "event" => random_string(),
              "private" => true
            }
          end)

        conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{"messages" => messages})

        Enum.each(messages_to_send, fn %{topic: topic} ->
          topic = Tenants.tenant_topic(tenant, topic, false)
          assert_called(Endpoint.broadcast_from(:_, topic, "broadcast", :_))
        end)

        assert_not_called(
          Endpoint.broadcast_from(:_, Tenants.tenant_topic(tenant, no_auth_channel.topic, false), "broadcast", :_)
        )

        assert_called_exactly(GenCounter.add(Tenants.events_per_second_key(tenant)), length(messages_to_send))

        assert conn.status == 202
      end
    end

    @tag role: "anon"
    test "user without permission won't broadcast", %{
      conn: conn,
      db_conn: db_conn,
      tenant: tenant
    } do
      with_mocks [
        {Endpoint, [:passthrough], broadcast_from: fn _, _, _, _ -> :ok end},
        {GenCounter, [:passthrough], add: fn _ -> :ok end}
      ] do
        messages =
          Stream.repeatedly(fn -> generate_message_with_policies(db_conn, tenant) end)
          |> Enum.take(5)

        # Duplicate messages to ensure same topics emit twice
        messages = messages ++ messages

        messages =
          Enum.map(messages, fn %{topic: topic} ->
            %{
              "topic" => topic,
              "payload" => %{"content" => random_string()},
              "event" => random_string(),
              "private" => true
            }
          end)

        conn = post(conn, Routes.broadcast_path(conn, :broadcast), %{"messages" => messages})

        Enum.each(messages, fn %{"topic" => topic} ->
          topic = Tenants.tenant_topic(tenant, topic)
          assert_not_called(Endpoint.broadcast_from(:_, topic, "broadcast", :_))
        end)

        assert_not_called(GenCounter.add(Tenants.events_per_second_key(tenant)))

        assert conn.status == 202
      end
    end
  end

  defp generate_message_with_policies(db_conn, tenant) do
    message = message_fixture(tenant)
    create_rls_policies(db_conn, [:authenticated_read_broadcast, :authenticated_write_broadcast], message)
    message
  end

  defp generate_conn(conn, tenant) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{@token}")
    |> then(&%{&1 | host: "#{tenant.external_id}.tealbase.com"})
  end
end
