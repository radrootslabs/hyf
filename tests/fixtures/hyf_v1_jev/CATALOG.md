# Acceptance case catalog

Status: every case is PLANNED. The package validates definitions only. Paths are relative to the archive root. Exact scenario data and assertions are in each listed JSON file.

| Case | Boundary / operation | Required from | Purpose |
|---|---|---|---|
| DM001_exact_quantity | domain / `quantity.compare` | S019 | Exact equality must satisfy an otherwise supported quantity requirement. |
| DM002_unknown_not_zero | domain / `field.decode` | S018 | Unknown is not a zero value. |
| DM003_mass_conversion | domain / `quantity.normalize` | S020 | Use exact fixture conversion and declared decimal scale. |
| DM004_approximation_retained | domain / `quantity.normalize` | S022 | Unit precision must not manufacture source certainty. |
| DM005_missing_pack_weight | domain / `pack.normalize` | S021 | Twenty boxes has no invented mass. |
| DM006_wrong_product_pack | domain / `pack.normalize` | S021 | A carrot pack rule does not normalize a tomato box. |
| DM007_dimension_mismatch | domain / `quantity.normalize` | S020 | Mass and volume require justified conversion evidence. |
| DM008_money_unknown | domain / `price.decode` | S023 | Unstated price is not free produce. |
| DM009_currency_mismatch | domain / `price.compare` | S087 | No implied foreign-exchange conversion. |
| DM010_relative_date_replay | domain / `date.resolve` | S025 | Replay uses source context rather than a new present date. |
| DM011_missing_zone | domain / `date.resolve` | S025 | A local expression without a zone cannot become an unambiguous instant. |
| DM012_ambiguous_local_time | domain / `date.resolve` | S026 | An ambiguous local time stays unresolved under the explicit test policy. |
| DM013_record_not_harvest | domain / `freshness.project` | S027 | A recently edited record does not establish a recent harvest. |
| DM014_unicode_evidence | domain / `evidence.validate` | S017 | Unicode offsets must select the intended original bytes/text. |
| DM015_wrong_revision_evidence | domain / `evidence.validate` | S017 | Even identical text does not erase an evidence revision mismatch. |
| DM016_numeric_overflow | domain / `quantity.decode` | S019 | Overflow fails explicitly instead of wrapping. |
| FU001_multiple_crops | application / `farm_update.interpret` | S067 | Separate crop claims, not one global availability state. |
| FU002_forecast | application / `farm_update.interpret` | S067 | Tentative future supply is not current stock. |
| FU003_negation | application / `farm_update.interpret` | S067 | Negation reverses the apparent product mention. |
| FU004_quantity_association | application / `farm_update.interpret` | S068 | Do not swap product-specific amounts. |
| FU005_addition | application / `farm_update.interpret` | S069 | Another is an addition claim, not a new total. |
| FU006_remaining | application / `farm_update.interpret` | S069 | Left is a remaining-balance report, not an increment. |
| FU007_total | application / `farm_update.interpret` | S069 | Total is a replacement/balance assertion under reviewed operation binding. |
| FU008_unknown_product | application / `farm_update.interpret` | S067 | Unsupported synthetic crop is not forced into tomatoes. |
| FU009_optional_price | application / `farm_update.interpret` | S072 | No price does not block a draft or permit publication. |
| FU010_unreserved_unknown | application / `farm_update.interpret` | S068 | Harvested total does not prove available stock. |
| FU011_ambiguous_withdrawal | application / `farm_update.interpret` | S070 | Ambiguous withdrawal target does not remove every basil lot. |
| FU012_linked_clarification | application / `farm_update.interpret` | S073 | Explicit follow-up refines a field without overwriting original source. |
| FU013_stale_clarification | application / `farm_update.interpret` | S073 | Stale clarification needs reconciliation. |
| FU014_provider_timeout | application / `farm_update.interpret` | S074 | Failed inference cannot silently confirm heuristic stock. |
| FU015_invalid_answer | application / `farm_update.interpret` | S074 | Failed inference cannot silently confirm heuristic stock. |
| BR001_multiple_lines | application / `buyer_request.interpret` | S075 | Preserve the stated buyer semantics and make unresolved information visible. |
| BR002_fulfillment_negation | application / `buyer_request.interpret` | S076 | Preserve the stated buyer semantics and make unresolved information visible. |
| BR003_delivery_preference | application / `buyer_request.interpret` | S076 | Preserve the stated buyer semantics and make unresolved information visible. |
| BR004_seconds_permitted | application / `buyer_request.interpret` | S076 | Preserve the stated buyer semantics and make unresolved information visible. |
| BR005_substitution_not_stated | application / `buyer_request.interpret` | S076 | Preserve the stated buyer semantics and make unresolved information visible. |
| BR006_conflicting_conditions | application / `buyer_request.interpret` | S078 | Preserve the stated buyer semantics and make unresolved information visible. |
| BR007_missing_quantity | application / `buyer_request.interpret` | S079 | Preserve the stated buyer semantics and make unresolved information visible. |
| BR008_no_reparse | application / `buyer_request.match` | S081 | Matching must use typed intent rather than legacy rewritten text. |
| BR009_provider_failure | application / `buyer_request.interpret` | S080 | Inference outage is not unavailable supply. |
| MT001_shortage | application / `buyer_request.match` | S089 | 50 kg required versus 30 kg cannot become eligible through semantic scoring. |
| MT002_unknown_quantity | application / `buyer_request.match` | S088 | Unknown unreserved quantity is conditional, not zero or sufficient. |
| MT003_exact_available | application / `buyer_request.match` | S088 | Exact required available quantity passes on fully supplied test premises. |
| MT004_wrong_product_high_score | domain / `eligibility.compose` | S083 | Wrong product cannot be rescued by maximum semantic preference. |
| MT005_fail_dominates_unknown | domain / `eligibility.compose` | S035 | Any mandatory failure dominates unresolved checks. |
| MT006_unknown_dominates_pass | domain / `eligibility.compose` | S035 | Unknown mandatory condition prevents eligible status. |
| MT007_optional_missing | domain / `eligibility.compose` | S035 | Missing optional preference is not a mandatory blocker. |
| MT008_delivery_mismatch | application / `buyer_request.match` | S085 | Delivery requirement cannot be a mere ranking penalty. |
| MT009_unknown_area | application / `buyer_request.match` | S085 | Delivery mention alone does not verify service area. |
| MT010_nonoverlap | application / `buyer_request.match` | S086 | Weekend similarity does not satisfy a specific Friday window. |
| MT011_certification_unverified | application / `buyer_request.match` | S084 | Marketing text and high confidence cannot verify certification. |
| MT012_two_compatible_lots | application / `buyer_request.match` | S091 | Compatible same-supplier lots jointly meet the need. |
| MT013_duplicate_lot | application / `buyer_request.match` | S082 | Duplicated 30 kg records do not make 60 kg. |
| MT014_conflicting_revisions | application / `buyer_request.match` | S082 | Two revisions are not two independent lots. |
| MT015_shared_lot_two_lines | application / `buyer_request.match` | S092 | One 50 kg lot cannot satisfy two 30 kg lines. |
| MT016_partial_allowed | application / `buyer_request.match` | S093 | Explicitly allowed partial outcome discloses the deficit. |
| MT017_multi_supplier_unsupported | application / `buyer_request.match` | S094 | Unsupported coordination is not proof of absent produce. |
| MT018_truncated_retrieval | application / `buyer_request.match` | S094 | No candidates in a truncated input is not global absence. |
| MT019_alternative_plans | domain / `plan.project` | S094 | Reused stock across alternatives is not simultaneous allocation. |
| MT020_unknown_not_midpoint | application / `buyer_request.match` | S095 | Missing evidence is not level one of a score. |
| MT021_score_normalization | domain / `score.normalize` | S097 | Normalize a three-level maximum by two, not assume raw value already normalized. |
| MT022_stable_ties | domain / `ranking.compose` | S098 | Stable test tie policy must not follow incidental input ordering. |
| MT023_ranking_outage | application / `buyer_request.match` | S100 | Outage labels advisory degradation without rewriting feasibility. |
| PV001_valid_all_types | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV002_missing_answer | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV003_extra_answer | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV004_wrong_type | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV005_unknown_choice | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV006_bad_distribution_sum | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV007_score_out_of_range | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV008_wrong_legend | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV009_model_mismatch | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV010_noul_out_of_range | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV011_missing_level | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV012_confidence_out_of_range | provider / `provider.decode` | S047 | Validate the provider contract independently from model accuracy. |
| PV013_auth_no_retry | transport / `provider.execute` | S062 | Retry only the declared transient category within the supplied test budget. |
| PV014_validation_no_retry | transport / `provider.execute` | S062 | Retry only the declared transient category within the supplied test budget. |
| PV015_capacity_retry | transport / `provider.execute` | S062 | Retry only the declared transient category within the supplied test budget. |
| PV016_overload_retry | transport / `provider.execute` | S062 | Retry only the declared transient category within the supplied test budget. |
| PV017_no_remaining_budget | transport / `provider.execute` | S062 | A nominal retryable status cannot create fresh time budget. |
| PV018_unexpected_call | harness / `harness.script` | S058 | Wrong protocol never falls through to live inference. |
| PV019_missing_call | harness / `harness.script` | S058 | Unconsumed expected calls fail the test. |
| PV020_wrong_request_state | harness / `harness.script` | S058 | Returning a canned answer without validating outbound state is forbidden. |
| PV021_invalid_json_bytes | provider / `provider.decode` | S047 | Invalid body reaches the actual provider decoder, not just fixture parsing. |
| PV022_nan_bytes | provider / `provider.decode` | S047 | Non-JSON/nonfinite number is rejected at the real boundary. |
| PR001_persistent | process / `stdio.session` | S102 | Persistent operation does not require one process per request. |
| PR002_valid_invalid_valid | process / `stdio.session` | S103 | Recover when framing is still known. |
| PR003_fragmented | process / `stdio.session` | S101 | Partial reads do not split semantic frames. |
| PR004_coalesced | process / `stdio.session` | S101 | One read can contain multiple requests. |
| PR005_escaped_newline | process / `stdio.session` | S101 | String content is not a framing delimiter. |
| PR006_size_limit | process / `stdio.session` | S103 | Oversized input has bounded failure, not unbounded draining. |
| PR007_partial_eof | process / `stdio.session` | S101 | Final EOF behavior is explicit, not a guessed payload assumption. |
| PR008_stderr_separation | process / `stdio.session` | S102 | Diagnostics cannot corrupt RPC framing. |
| PR009_shutdown_cleanup | process / `stdio.session` | S110 | Persistent lifecycle failures clean up owned resources. |
| PR010_one_inflight | process / `stdio.session` | S102 | Single-inflight contract remains explicit. |
| SC001_cross_tenant | security / `security.boundary` | S114 | Cross-tenant records are not authorized by their presence in input. |
| SC002_consumer_not_auth | security / `security.boundary` | S114 | A descriptive consumer string is not authentication. |
| SC003_instruction_in_source | security / `security.boundary` | S115 | Source instructions remain data. |
| SC004_state_minimization | security / `security.boundary` | S050 | Only relevant authorized state is sent. |
| SC005_secret_redaction | security / `security.boundary` | S116 | Failures do not disclose configuration secrets. |
| SC006_external_plaintext | security / `security.boundary` | S061 | External plaintext must not be allowed by the loopback test exception. |
| SC007_wrong_tls_host | security / `security.boundary` | S061 | Actual transport verifies hostnames. |
| SC008_untrusted_tls_ca | security / `security.boundary` | S061 | Unknown issuer is not accepted. |
| SC009_redirect_secret | security / `security.boundary` | S061 | Redirect policy cannot leak bearer credentials. |
| SC010_request_endpoint_override | security / `security.boundary` | S054 | Untrusted input cannot choose infrastructure. |
| SC011_offline_secret_env | security / `security.boundary` | S122 | Default tests isolate developer configuration. |
| SC012_provider_disabled | security / `security.boundary` | S108 | Configured provider does not override assistance permission. |
| JR001_farm_review_handoff | journey / `farm_update.interpret` | S111 | Complete farm journey keeps confirmation and mutation outside Hyf. |
| JR002_buyer_match_revalidate | journey / `buyer_request.match` | S112 | Typed intent survives interpretation through an explicitly non-reserving match. |
| JR003_duplicate_acceptance | journey / `authority.simulation` | S113 | Simulation defines duplicate handling; real-service evidence remains a separate gate. |
| JR004_stale_acceptance | journey / `authority.simulation` | S113 | Expected-version write fails when authority state changed. |
| JR005_stock_race | journey / `authority.simulation` | S113 | A match is not a lock on stock. |
| RT001_shared_budget | application / `budget.execute` | S055 | Stages share the original budget; no stage gets a fresh deadline. |
| RT002_circuit_liveness | application / `runtime.health` | S057 | Local liveness is not external readiness. |
| RT003_resource_soak | process / `process.soak` | S125 | Resource checks are separate from live latency claims. |
| RT004_no_cache_or_isolated_cache | security / `cache.policy` | S117 | No cache is valid; any actual cache must satisfy isolation. |
