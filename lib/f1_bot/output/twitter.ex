defmodule F1Bot.Output.Twitter do
  @moduledoc """
  Listens for events published by `F1Bot.F1Session.Server`, composes messages for Twitter
  and calls a configured Twitter client (live or console) to send them.
  """
  use GenServer
  require Logger
  alias F1Bot.F1Session.Common.Helpers
  alias F1Bot.DataTransform.Format

  @post_after_race_lap 5

  @common_hashtags "#f1"

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: server_via())
  end

  @impl true
  def init(_init_arg) do
    Helpers.subscribe_to_event(:aggregate_stats, :fastest_lap)
    Helpers.subscribe_to_event(:aggregate_stats, :top_speed)
    Helpers.subscribe_to_event(:driver, :tyre_change)
    Helpers.subscribe_to_event(:session_status, :started)
    Helpers.subscribe_to_event(:race_control, :message)

    state = %{}

    {:ok, state}
  end

  @impl true
  def handle_info(
        %{
          scope: :aggregate_stats,
          type: :fastest_lap,
          payload: %{
            driver_number: driver_number,
            lap_time: lap_time,
            lap_delta: lap_delta,
            type: overall_or_personal
          }
        },
        state
      ) do
    if should_post_stats() do
      driver = get_driver_name_by_number(driver_number)

      lap_time = Format.format_lap_time(lap_time)
      lap_delta = Format.format_lap_delta(lap_delta)

      type =
        case overall_or_personal do
          :overall -> "the fastest lap"
          :personal -> "a personal fastest lap"
        end

      type_hashtag =
        case overall_or_personal do
          :overall -> "#FastestLap #PersonalFastestLap"
          :personal -> "#PersonalFastestLap"
        end

      msg =
        """
        #{driver} just set #{type} of #{lap_time} (Δ #{lap_delta})
        #{type_hashtag} ##{get_driver_abbr_by_number(driver_number)} #{@common_hashtags} #{ts_hashtag()}
        """
        |> String.trim()

      F1Bot.ExternalApi.Twitter.post_tweet(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{
          scope: :aggregate_stats,
          type: :top_speed,
          payload: %{
            driver_number: driver_number,
            speed: speed,
            speed_delta: speed_delta,
            type: overall_or_personal
          }
        },
        state
      ) do
    if overall_or_personal == :overall do
      driver = get_driver_name_by_number(driver_number)

      type =
        case overall_or_personal do
          :overall -> "an overall top speed"
          :personal -> "personal top speed"
        end

      msg =
        """
        #{driver} reached #{type} of #{speed} km/h (Δ +#{speed_delta} km/h) at some point in the previous lap.
        #TopSpeed ##{get_driver_abbr_by_number(driver_number)} #{@common_hashtags} #{ts_hashtag()}
        """
        |> String.trim()

      F1Bot.ExternalApi.Twitter.post_tweet(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{
          scope: :driver,
          type: :tyre_change,
          payload: %{
            driver_number: driver_number,
            is_correction: _is_correction,
            compound: compound,
            age: age
          }
        },
        state
      ) do
    with {:ok, :started} <- F1Bot.session_status() do
      driver = get_driver_name_by_number(driver_number)

      age_str =
        if age == 0 do
          "new"
        else
          "#{age} laps old"
        end

      msg =
        """
        #{driver} pitted for #{age_str} #{compound} tyres.
        #PitStop ##{get_driver_abbr_by_number(driver_number)} #{@common_hashtags} #{ts_hashtag()}
        """
        |> String.trim()

      F1Bot.ExternalApi.Twitter.post_tweet(msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{
          scope: :session_status,
          type: :started,
          payload: %{
            gp_name: gp_name,
            session_type: session_type
          }
        },
        state
      ) do
    session_name = "#{gp_name} - #{session_type}"

    msg =
      """
      #{session_name} just started!
      #SessionStarted #{@common_hashtags} #{ts_hashtag()}
      """
      |> String.trim()

    F1Bot.ExternalApi.Twitter.post_tweet(msg)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{
          scope: :race_control,
          type: :message,
          payload: %{
            # flag: flag,
            message: message,
            mentions: mentions,
            source: source
          }
        },
        state
      ) do
    driver_hashtags =
      for abbr <- mentions do
        "##{abbr}"
      end
      |> Enum.join(" ")

    source_prefix =
      case source do
        :stewards -> "FIA Stewards"
        :stewards_correction -> "FIA Stewards correction"
        _ -> "Race Control"
      end

    source_hashtag =
      case source do
        :stewards -> "#FIAStewards"
        :stewards_correction -> "#FIAStewards"
        _ -> "#RaceControl"
      end

    msg =
      """
      #{source_prefix}: #{message}
      #{source_hashtag} #{driver_hashtags} #{@common_hashtags} #{ts_hashtag()}
      """
      |> String.trim()

    F1Bot.ExternalApi.Twitter.post_tweet(msg)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Logger.info("Ignored output message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp should_post_stats() do
    case F1Bot.lap_number() do
      {:ok, lap} -> lap > @post_after_race_lap or not F1Bot.is_race?()
      _ -> not F1Bot.is_race?()
    end
  end

  defp get_driver_name_by_number(driver_number) do
    case F1Bot.driver_info(driver_number) do
      {:ok, %{last_name: name}} -> name
      {:error, _} -> "Car #{driver_number}"
    end
  end

  defp get_driver_abbr_by_number(driver_number) do
    case F1Bot.driver_info(driver_number) do
      {:ok, %{driver_abbr: abbr}} -> abbr
      {:error, _} -> "Car#{driver_number}"
    end
  end

  defp ts_hashtag do
    {:ok, ts} = Timex.now() |> Timex.format("{0h24}{0m}{0s}")
    "#T#{ts}"
  end

  defp server_via() do
    __MODULE__
  end
end