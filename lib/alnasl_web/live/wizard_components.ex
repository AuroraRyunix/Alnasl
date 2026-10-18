defmodule AlnaslWeb.WizardComponents do
  @moduledoc """
  The Setup wizard section of Setup (`/setup/wizard`): first the questions
  (what the hall looks like), then the steps for exactly that hall, in
  order, each with its tick and the one button that goes where the step is
  done (`Alnasl.Wizard` decides the steps and the ticks).

  The first step not done is the current one and looks it; the ones done
  get quiet. A step the account cannot act on keeps its tick and loses its
  button, and says who can.
  """

  use AlnaslWeb, :html

  alias Alnasl.Wizard

  @arkab_releases "https://github.com/teapot-chess/Arkab/releases/latest"
  @polis_releases "https://github.com/teapot-chess/Polis/releases/latest"
  @nunki_releases "https://github.com/teapot-chess/Nunki/releases/latest"

  @doc "Where Arkab is downloaded."
  def arkab_releases, do: @arkab_releases

  attr :plan, :map, required: true
  attr :form, :any, required: true, doc: "the questions, as a form"
  attr :editing?, :boolean, default: false
  attr :server?, :boolean, required: true
  attr :own_hall?, :boolean, required: true
  attr :scope, :any, required: true
  attr :hall_id, :integer, required: true
  attr :may_answer?, :boolean, default: true

  def wizard(assigns) do
    assigns =
      assign(assigns,
        extras: Wizard.extras(%{server?: assigns.server?, own_hall?: assigns.own_hall?}),
        asking?: assigns.editing? or assigns.plan.answers == nil
      )

    ~H"""
    <.panel id="setup-wizard" title={gettext("Setup wizard")}>
      <:actions><AlnaslWeb.Components.ManualLink.manual_link topic={:wizard} /></:actions>

      <p class="note">
        <%= if @server? do %>
          {gettext(
            "On the server the boards come from Arkab: a small program on a computer beside the boards (a Raspberry Pi will do) that reads them and sends them here. Say what this hall looks like, and the wizard lists what to do, in order, ticking off each step as it really happens."
          )}
        <% else %>
          {gettext(
            "On this box the boards are plugged into this computer. Say what this hall looks like, and the wizard lists what to do, in order, ticking off each step as it really happens."
          )}
        <% end %>
      </p>

      <%= if @asking? do %>
        <.questions
          form={@form}
          server?={@server?}
          extras={@extras}
          may_answer?={@may_answer?}
          answered?={@plan.answers != nil}
        />
      <% else %>
        <div class="row">
          <p id="wizard-summary" class="note">{summary(@plan.answers, @server?)}</p>
          <.button
            :if={@may_answer?}
            id="wizard-change"
            small
            variant="ghost"
            phx-click="wizard_edit"
          >
            {gettext("Change the answers")}
          </.button>
        </div>

        <p :if={@plan.complete?} id="wizard-complete" class="callout" role="status">
          <.icon name="ok" />
          {gettext(
            "Every step is done. Setup opens on Tournaments from now on; this wizard stays here for the next change."
          )}
        </p>

        <ol id="wizard-steps" class="wsteps">
          <.step
            :for={{s, i} <- Enum.with_index(@plan.steps, 1)}
            step={s}
            n={i}
            current?={s.key == @plan.current}
            may?={Wizard.can?(@scope, s, @hall_id)}
            hall_id={@hall_id}
            server?={@server?}
            own_hall?={@own_hall?}
          />
        </ol>
      <% end %>
    </.panel>
    """
  end

  attr :form, :any, required: true
  attr :server?, :boolean, required: true
  attr :extras, :list, required: true
  attr :may_answer?, :boolean, required: true
  attr :answered?, :boolean, required: true

  defp questions(assigns) do
    shape = assigns.form[:shape].value || "simple"
    chosen = List.wrap(assigns.form[:extras].value)
    assigns = assign(assigns, shape: shape, chosen: chosen)

    ~H"""
    <%= if @may_answer? do %>
      <.form
        for={@form}
        id="wizard-form"
        phx-change="wizard_change"
        phx-submit="save_wizard"
        class="stack"
      >
        <.input
          field={@form[:shape]}
          id="wizard-shape"
          type="select"
          label={gettext("What does this hall look like?")}
          options={shape_options(@server?)}
        />
        <div class="form-grid">
          <.input
            :if={@server? and @shape == "halls"}
            field={@form[:halls]}
            id="wizard-halls"
            type="number"
            min="1"
            max="50"
            label={gettext("How many halls")}
          />
          <.input
            :if={@server? or @shape == "halls"}
            field={@form[:bridges]}
            id="wizard-bridges"
            type="number"
            min="1"
            max="50"
            label={
              if(@server?,
                do: gettext("Arkab bridges in this hall"),
                else: gettext("Arkab bridges, for the other rooms")
              )
            }
            hint={
              gettext(
                "One per computer beside a group of boards: boards split over rooms or far-apart tables need one each."
              )
            }
          />
          <.input
            field={@form[:boards]}
            id="wizard-boards"
            type="number"
            min="1"
            max="500"
            label={
              if(@server?,
                do: gettext("Boards per bridge, roughly"),
                else: gettext("Boards on this computer, roughly")
              )
            }
            hint={
              gettext(
                "One cable chain takes up to twelve boards; more boards are a second chain on a port of its own."
              )
            }
          />
          <.input
            :if={@shape == "tournaments"}
            field={@form[:tournaments]}
            id="wizard-tournaments"
            type="number"
            min="2"
            max="50"
            label={gettext("How many tournaments")}
          />
        </div>

        <fieldset id="wizard-extras" class="field">
          <legend>{gettext("And also")}</legend>
          <label :for={x <- @extras} class="check" for={"wizard-extra-#{x}"}>
            <input
              type="checkbox"
              id={"wizard-extra-#{x}"}
              name="wizard[extras][]"
              value={x}
              checked={x in @chosen}
            />
            <span>{extra_label(x)}</span>
          </label>
        </fieldset>

        <div class="row">
          <.button id="wizard-save" variant="primary" type="submit">
            {if(@answered?, do: gettext("Show the steps again"), else: gettext("Show the steps"))}
          </.button>
          <.button
            :if={@answered?}
            id="wizard-cancel"
            type="button"
            variant="ghost"
            phx-click="wizard_cancel"
          >
            {gettext("Cancel")}
          </.button>
        </div>
      </.form>
    <% else %>
      <p id="wizard-unanswered" class="note">
        {gettext("The hall's owner answers the wizard's questions; then the steps appear here.")}
      </p>
    <% end %>
    """
  end

  defp shape_options(true) do
    [
      {gettext("One hall, one tournament"), "simple"},
      {gettext("One hall, several tournaments"), "tournaments"},
      {gettext("Several halls or rooms"), "halls"}
    ]
  end

  defp shape_options(false) do
    [
      {gettext("One hall, this computer with the boards, one tournament"), "simple"},
      {gettext("One hall, several tournaments"), "tournaments"},
      {gettext("Several rooms: boards elsewhere come through Arkab"), "halls"}
    ]
  end

  defp extra_label("results"), do: gettext("Results for spectators on OpenResults")
  defp extra_label("lichess"), do: gettext("A Lichess broadcast")
  defp extra_label("polis"), do: gettext("A print station (Polis) for pairings and place cards")
  defp extra_label("nunki"), do: gettext("A hall announcer (Nunki) that reads the pairings aloud")
  defp extra_label("phone"), do: gettext("Phones and laptops in the hall, behind a PIN")

  defp summary(a, server?) do
    shape =
      case a["shape"] do
        "simple" -> gettext("One hall, one tournament")
        "tournaments" -> gettext("One hall, %{count} tournaments", count: a["tournaments"])
        "halls" when server? -> gettext("%{count} halls", count: a["halls"])
        "halls" -> gettext("Several rooms")
      end

    boards =
      if server? or a["shape"] == "halls",
        do: ngettext("%{count} Arkab bridge", "%{count} Arkab bridges", a["bridges"])

    per =
      if server?,
        do:
          ngettext(
            "about %{count} board per bridge",
            "about %{count} boards per bridge",
            a["boards"]
          ),
        else: ngettext("about %{count} board", "about %{count} boards", a["boards"])

    [shape, boards, per]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # --- a step ------------------------------------------------------------------

  attr :step, :map, required: true
  attr :n, :integer, required: true
  attr :current?, :boolean, required: true
  attr :may?, :boolean, required: true
  attr :hall_id, :integer, required: true
  attr :server?, :boolean, required: true
  attr :own_hall?, :boolean, required: true

  defp step(assigns) do
    {title, text} = words(assigns.step, assigns)
    assigns = assign(assigns, title: title, text: text, go: go(assigns.step, assigns))

    ~H"""
    <li
      id={"wizard-step-#{slug(@step.key)}"}
      class={["wstep", @step.done? && "done", @current? && "current"]}
      aria-current={@current? && "step"}
    >
      <span class="wstep-n" aria-hidden="true">
        <%= if @step.done? do %>
          <.icon name="ok" />
        <% else %>
          {@n}
        <% end %>
      </span>
      <div class="wstep-body">
        <div class="wstep-line">
          <b>{@title}</b>
          <.badge :if={@step.done?} id={"wizard-step-#{slug(@step.key)}-done"} tone="ok">
            {if(@step.manual?, do: gettext("marked done"), else: gettext("done"))}
          </.badge>
          <.badge
            :if={match?({:bridge, _}, @step.key) and @step.done? and not @step.live?}
            id={"wizard-step-#{slug(@step.key)}-offline"}
            tone="warn"
            icon="offline"
          >
            {gettext("not connected now")}
          </.badge>
        </div>
        <p :if={not @step.done? or @current?} class="note">{@text}</p>

        <div :if={not @step.done?} class="row">
          <%= cond do %>
            <% not @may? -> %>
              <p id={"wizard-step-#{slug(@step.key)}-who"} class="note">{who(@step.can)}</p>
            <% @go != nil -> %>
              <% {label, to, kind} = @go %>
              <.button
                :if={kind == :external}
                id={"wizard-step-#{slug(@step.key)}-go"}
                href={to}
                target="_blank"
                rel="noopener"
                variant={if(@current?, do: "primary", else: "ghost")}
                small={not @current?}
                icon="external"
              >
                {label}
              </.button>
              <.button
                :if={kind == :navigate}
                id={"wizard-step-#{slug(@step.key)}-go"}
                navigate={to}
                variant={if(@current?, do: "primary", else: "ghost")}
                small={not @current?}
              >
                {label}
              </.button>
            <% true -> %>
          <% end %>
          <.button
            :if={@step.manual? and @may?}
            id={"wizard-step-#{slug(@step.key)}-mark"}
            small
            variant="ghost"
            phx-click="wizard_mark"
            phx-value-key={slug(@step.key)}
            phx-value-done="true"
          >
            {gettext("Mark as done")}
          </.button>
        </div>
        <div :if={@step.done? and @step.manual? and @may?} class="row">
          <.button
            id={"wizard-step-#{slug(@step.key)}-unmark"}
            small
            variant="ghost"
            phx-click="wizard_mark"
            phx-value-key={slug(@step.key)}
            phx-value-done="false"
          >
            {gettext("Not done after all")}
          </.button>
        </div>
      </div>
    </li>
    """
  end

  @doc "A step's address in the page: `arkab`, `bridge-2`."
  def slug({:bridge, i}), do: "bridge-#{i}"
  def slug(key) when is_atom(key), do: Atom.to_string(key)

  defp who(:admin), do: gettext("An admin does this one.")
  defp who(:owner), do: gettext("The hall's owner does this one.")
  defp who(_arbiter), do: gettext("An arbiter of this hall does this one.")

  defp count(%{have: have, want: want}), do: "#{have}/#{want}"

  defp words(%{key: :halls} = s, _a) do
    {gettext("Make the halls (%{count})", count: count(s)),
     gettext(
       "Halls, \"A new hall\": one per room or venue with boards. Then open this wizard in each of them (the hall picker at the top) for its own steps."
     )}
  end

  defp words(%{key: :plug} = s, _a) do
    {gettext("Plug the boards into this computer (%{count})", count: count(s)),
     gettext(
       "Boards, \"Add a board\": choose the port the cable is in and press Add. A chain of boards on one cable is found board by board, up to twelve."
     )}
  end

  defp words(%{key: :arkab}, _a) do
    {gettext("Install Arkab beside the boards"),
     gettext(
       "Arkab is the bridge: it runs on a small computer next to the boards (a Raspberry Pi, a mini PC, a laptop) with the boards plugged into it. Download it from its releases page and start it; its own page then opens on that computer, on port 4050. This step is ticked once a bridge of this hall has connected."
     )}
  end

  defp words(%{key: {:bridge, i}, of: n} = s, _a) do
    title =
      if n > 1,
        do: gettext("Bridge %{i} of %{n}: join it to this hall", i: i, n: n),
        else: gettext("Join the bridge to this hall")

    text =
      cond do
        s.joined? and not s.done? ->
          gettext(
            "\"%{name}\" has joined but has not connected yet. Check that Arkab is running and that its computer has internet.",
            name: s.name
          )

        true ->
          gettext(
            "Halls, this hall, Bridges: press \"Add a bridge\". On Arkab's page, under \"Join a server\", paste the link it shows or press Scan and point the camera at the code, then Join. The link is good for one bridge and fifteen minutes."
          )
      end

    {title, text}
  end

  defp words(%{key: :boards} = s, _a) do
    {gettext("Boards arriving from the bridges (%{count})", count: count(s)),
     gettext(
       "Plug the boards into the bridge's computer. Each one that answers appears on Boards here within some ten seconds. A port the bridge does not read yet: Halls, this hall, Bridges, \"Read\"."
     )}
  end

  defp words(%{key: :connect, want: want} = s, _a) do
    title =
      if want > 1,
        do: gettext("Connect the tournaments from OpenPairings (%{count})", count: count(s)),
        else: gettext("Connect the tournament from OpenPairings")

    {title,
     gettext(
       "In OpenPairings, open the tournament, then Settings, Live boards, and press \"New code\" (a code for a group brings all its tournaments at once). Paste the code here under Setup, Connections, \"+ Add\". Pairings, colours and the results page come with it."
     )}
  end

  defp words(%{key: :tables}, _a) do
    {gettext("Say which tables play in which tournament"),
     gettext(
       "Setup, Tournaments: open each tournament and give it its tables (tables 1 to 10, 11 to 16...). One tournament may keep every table nobody else has; the others need a range."
     )}
  end

  defp words(%{key: :number} = s, _a) do
    {gettext("Number the boards (%{count})", count: count(s)),
     gettext(
       "Boards, \"Number the boards\": press Start, then lift a piece on table 1's board, then table 2's, and so on. A phone in one hand is the way to do it."
     )}
  end

  defp words(%{key: :results}, a) do
    {gettext("Results for spectators"),
     if(a.own_hall?,
       do:
         gettext(
           "A tournament from OpenPairings brings its results page with it (there: the tournament's Settings, OpenResults). The hall's own tournament gets one under Setup, Results and Lichess. Ticked once a tournament here has a results page and its relay key."
         ),
       else:
         gettext(
           "A tournament from OpenPairings brings its results page with it (there: the tournament's Settings, OpenResults). Ticked once a tournament here has a results page and its relay key."
         )
     )}
  end

  defp words(%{key: :lichess}, _a) do
    {gettext("A Lichess broadcast"),
     gettext(
       "Setup, Results and Lichess: paste the Lichess round and a token that may broadcast. Ticked once a tournament here has both."
     )}
  end

  defp words(%{key: :phone}, _a) do
    {gettext("Phones and laptops in the hall"),
     gettext(
       "Setup, Access: let other machines in the hall open this site, and set a PIN so a spectator's phone gets the question and nothing else. Ticked once other machines are let in."
     )}
  end

  defp words(%{key: :polis}, _a) do
    {gettext("A print station (Polis)"),
     gettext(
       "Install Polis on the computer with the printer. In OpenPairings, open the tournament's \"Print station\" page and press \"Add a print station\"; paste the link into \"Join a tournament\" on Polis's page and choose the printer. Polis talks to OpenPairings, not to Alnasl, so mark this done yourself."
     )}
  end

  defp words(%{key: :nunki}, _a) do
    {gettext("A hall announcer (Nunki)"),
     gettext(
       "Install Nunki on the computer with the speakers. In OpenPairings, open the tournament's \"Hall announcer\" page and press \"Add an announcer\"; paste the link into \"Join a tournament\" on Nunki's page. Nunki talks to OpenPairings, not to Alnasl, so mark this done yourself."
     )}
  end

  defp go(%{key: :halls}, _a), do: {gettext("Halls"), ~p"/halls", :navigate}
  defp go(%{key: :plug}, _a), do: {gettext("Boards"), ~p"/boards", :navigate}
  defp go(%{key: :arkab}, _a), do: {gettext("Download Arkab"), @arkab_releases, :external}

  defp go(%{key: {:bridge, _}}, a),
    do: {gettext("Bridges of this hall"), ~p"/halls/#{a.hall_id}/bridges", :navigate}

  defp go(%{key: :boards}, _a), do: {gettext("Boards"), ~p"/boards", :navigate}
  defp go(%{key: :connect}, _a), do: {gettext("Connections"), ~p"/setup/connections", :navigate}
  defp go(%{key: :tables}, _a), do: {gettext("Tournaments"), ~p"/setup/tournaments", :navigate}

  defp go(%{key: :number}, _a),
    do: {gettext("Number the boards"), ~p"/boards/number", :navigate}

  defp go(%{key: :results}, %{own_hall?: true}),
    do: {gettext("Results and Lichess"), ~p"/setup/results", :navigate}

  defp go(%{key: :results}, _a), do: {gettext("Tournaments"), ~p"/setup/tournaments", :navigate}

  defp go(%{key: :lichess}, _a),
    do: {gettext("Results and Lichess"), ~p"/setup/results", :navigate}

  defp go(%{key: :phone}, _a), do: {gettext("Access"), ~p"/setup/access", :navigate}
  defp go(%{key: :polis}, _a), do: {gettext("Download Polis"), @polis_releases, :external}
  defp go(%{key: :nunki}, _a), do: {gettext("Download Nunki"), @nunki_releases, :external}
end
