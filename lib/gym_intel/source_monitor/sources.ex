defmodule GymIntel.SourceMonitor.Sources do
  @moduledoc "Fixed public evidence routes for the four working gym brands. No crawling."

  @sources [
    %{
      id: "gymnation_offer",
      gym: "GymNation",
      label: "Downtown Core branch page",
      url: "https://gymnation.com/en-ae/gymsnearme/downtown-dubai/",
      anchors: ["downtown", "core"],
      coverage: "Branch page only; selected joining fees require manual review."
    },
    %{
      id: "gymnation_terms",
      gym: "GymNation",
      label: "Membership terms",
      url: "https://gymnation.com/en-ae/terms-conditions/",
      anchors: ["membership", "terms"],
      coverage: "General terms; applicability to Downtown Core requires review."
    },
    %{
      id: "puregym_offer",
      gym: "PureGym",
      label: "Al Barsha joining selector",
      url: "https://puregym-arabia.exerp.site/join/plan?center=8002",
      anchors: ["al barsha", "core"],
      coverage: "Interactive selector; server HTML may omit the selected price."
    },
    %{
      id: "puregym_terms",
      gym: "PureGym",
      label: "UAE membership terms",
      url: "https://uae.puregymarabia.com/terms-conditions",
      anchors: ["membership", "terms"],
      coverage: "General terms; selected-plan and cancellation conflicts need review."
    },
    %{
      id: "warehouse_offer",
      gym: "The Warehouse Gym",
      label: "Light membership selector",
      url: "https://whgym.com/join",
      anchors: ["light", "battuta"],
      coverage: "Interactive selector; access scope remains unresolved."
    },
    %{
      id: "lamaison_offer",
      gym: "La Maison de la Masse",
      label: "Open gym pricing",
      url: "https://lamaisondelamasse.com/pricing/",
      anchors: ["monthly", "gym"],
      coverage: "Published pricing only; VAT, extra fees and availability are not certified."
    },
    %{
      id: "lamaison_scope",
      gym: "La Maison de la Masse",
      label: "Al Quoz gym access",
      url: "https://lamaisondelamasse.com/private-gym-dubai/",
      anchors: ["al quoz", "gym"],
      coverage: "Published gym description only; capacity is not verified."
    }
  ]

  def all, do: @sources
  def urls, do: Enum.map(@sources, & &1.url)
end
