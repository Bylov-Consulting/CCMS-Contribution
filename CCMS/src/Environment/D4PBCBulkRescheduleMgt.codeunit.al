namespace D4P.CCMS.Environment;

codeunit 62004 "D4P BC Bulk Reschedule Mgt"
{
    var
        // Per-env fetch result carried across the TryFunction boundary. AL's
        // [TryFunction] semantics make it awkward to pass a var Record param to a
        // function that also invokes an interface method, so we stage the result here.
        TempFetchBuffer: Record "D4P BC Available Update" temporary;
        // Per-env raw JSON cache populated during BuildPlan and forwarded to the dialog so
        // AssistEdit drilldowns can re-parse without a second API round-trip.
        FetchCache: Dictionary of [Text, Text];
        AdminAPI: Interface "D4P IBC Admin API";
        // Companion to TempFetchBuffer: the raw JSON payload for the most recent fetch,
        // staged across the TryFunction boundary so BuildPlan can push it into the per-env
        // cache consumed by the dialog's AssistEdit drilldown.
        TempFetchRawResponse: Text;
        AdminAPIInjected: Boolean;
        UnknownErrorLbl: Label 'unknown error';
        // Shared between BuildPlan (stamps the reason) and AnyFetchFailure (detects it). Keeping a
        // single label avoids a magic-string drift between where a fetch failure is written and read.
        FetchFailedReasonLbl: Label 'Fetch failed: %1', Comment = '%1 = Error message from GetLastErrorText';
        NoSelectionErr: Label 'Select one or more environments before bulk rescheduling.';
        ConfirmMsg: Label 'Reschedule updates for %1 environment(s)?', Comment = '%1 = Number of environments';
        FetchingMsg: Label 'Fetching available updates for the selected environments...';
        NothingToRescheduleMsg: Label 'Nothing to reschedule — none of the selected environments has an update available.';
        NoUpdatesLbl: Label 'No updates available';
        DefaultDatePastLbl: Label 'Default update date %1 has already passed and would be rejected; reschedule this environment manually.', Comment = '%1 = the latest selectable date that is now in the past';
        SkippedBySubscriberLbl: Label 'Skipped by subscriber';
        EnvGoneErr: Label 'Environment %1 no longer exists in the local database.', Comment = '%1 = Environment Name';
        APIFailureErr: Label 'Admin API reported the reschedule request failed.';

    /// <summary>
    /// Test seam: injects a custom API implementation. Intended for CCMS.Test only.
    /// In production, the default <see cref="Codeunit::D4P BC Admin API"/> is used
    /// automatically via <c>EnsureAdminAPI</c>. Calling this from a non-test context
    /// is supported but semantically risky — a non-authenticating or mis-routed
    /// implementation would be used for every subsequent API call in this session.
    /// </summary>
    /// <param name="NewAPI">The implementation to use for all subsequent API calls.</param>
    internal procedure SetAdminAPI(NewAPI: Interface "D4P IBC Admin API")
    begin
        AdminAPI := NewAPI;
        AdminAPIInjected := true;
    end;

    /// <summary>
    /// Full flow: empty-selection guard, Confirm, BuildPlan -> user review via page 62035 ->
    /// ApplyPlan -> ShowSummary (page 62033).
    /// </summary>
    procedure RunBulkReschedule(var BCEnvironment: Record "D4P BC Environment")
    var
        TempPlan: Record "D4P BC Reschedule Plan Line" temporary;
        TempPendingCheck: Record "D4P BC Reschedule Plan Line" temporary;
        BulkDialog: Page "D4P Bulk Reschedule Dialog";
        FetchDialog: Dialog;
        DialogFetchCache: Dictionary of [Text, Text];
        EnvCount: Integer;
    begin
        EnsureAdminAPI();

        if BCEnvironment.IsEmpty() then
            Error(NoSelectionErr);

        EnvCount := BCEnvironment.Count();
        if not Confirm(ConfirmMsg, false, EnvCount) then
            exit;

        // BuildPlan itself does no UI — a single indeterminate progress dialog is adequate
        // because phase-1 is typically sub-second-per-env and partners have already confirmed.
        // Per-env progress would require threading the dialog through BuildPlan's signature,
        // which the test-engineer intentionally kept clean.
        FetchDialog.Open(FetchingMsg);
        BuildPlan(BCEnvironment, TempPlan);
        FetchDialog.Close();

        // If every row ended up Skipped (no available updates / all fetches failed) there's
        // nothing the user can act on, so short-circuit instead of opening a dead dialog.
        TempPendingCheck.Copy(TempPlan, true);
        TempPendingCheck.Reset();
        TempPendingCheck.SetRange(Result, TempPendingCheck.Result::Pending);
        if TempPendingCheck.IsEmpty() then begin
            // No actionable rows. But "every fetch failed" must NOT masquerade as "no updates
            // available": that hides the per-env failure Reasons from the partner. When the plan
            // carries at least one fetch-failure row, open the summary so those Reasons are visible;
            // only the genuine no-updates case shows the generic message.
            if AnyFetchFailure(TempPlan) then
                ShowSummary(TempPlan)
            else
                Message(NothingToRescheduleMsg);
            exit;
        end;

        BulkDialog.SetData(TempPlan);
        // Forward the orchestrator's (potentially mocked) interface into the dialog so the
        // AssistEdit drilldown uses the same seam — no more bypass via `new Codeunit`.
        BulkDialog.SetAdminAPI(AdminAPI);
        // Warm the dialog's per-env cache with the raw JSONs BuildPlan already fetched —
        // turns a click-on-AssistEdit from a second API round-trip into a dictionary lookup.
        GetFetchCache(DialogFetchCache);
        BulkDialog.SetFetchCache(DialogFetchCache);
        BulkDialog.RunModal();
        if not BulkDialog.WasAccepted() then
            exit;

        BulkDialog.GetData(TempPlan);

        ApplyPlan(TempPlan);

        ShowSummary(TempPlan);
    end;

    /// <summary>
    /// Iterates BCEnvironment, populates TempPlan. Per-env fetch failures are caught
    /// via a TryFunction and recorded as Skipped rows (not propagated). Envs with an
    /// empty update list are also marked Skipped with a descriptive reason.
    /// </summary>
    procedure BuildPlan(var BCEnvironment: Record "D4P BC Environment"; var TempPlan: Record "D4P BC Reschedule Plan Line" temporary)
    var
        Parser: Codeunit "D4P BC Update Parser";
        TargetVersion: Text[100];
        DefaultDate: Date;
        ExpectedMonth: Integer;
        ExpectedYear: Integer;
        EntryNo: Integer;
        AvailableFlag: Boolean;
        FetchReason: Text;
    begin
        EnsureAdminAPI();

        TempPlan.Reset();
        TempPlan.DeleteAll(false);

        // Reset the per-env raw-JSON cache at the start of every BuildPlan run. Without
        // this, a second BuildPlan on the same orchestrator instance would serve stale
        // fixture data into AssistEdit drilldowns for the previous invocation's envs.
        Clear(FetchCache);

        if not BCEnvironment.FindSet() then
            exit;

        EntryNo := 0;
        repeat
            EntryNo += 1;

            TempPlan.Init();
            TempPlan."Entry No." := EntryNo;
            TempPlan."Customer No." := BCEnvironment."Customer No.";
            TempPlan."Tenant ID" := BCEnvironment."Tenant ID";
            TempPlan."Environment Name" := CopyStr(BCEnvironment.Name, 1, MaxStrLen(TempPlan."Environment Name"));
            TempPlan."Application Family" := BCEnvironment."Application Family";
            TempPlan."Current Version" := BCEnvironment."Current Version";
            TempPlan.Result := TempPlan.Result::Pending;

            ClearFetchBuffer();
            if not TryFetchUpdates(BCEnvironment) then begin
                FetchReason := GetLastErrorText();
                if FetchReason = '' then
                    FetchReason := UnknownErrorLbl;
                TempPlan.Result := TempPlan.Result::Skipped;
                TempPlan.Reason := CopyStr(StrSubstNo(FetchFailedReasonLbl, FetchReason), 1, MaxStrLen(TempPlan.Reason));
            end else begin
                // Cache the raw JSON under the env's full composite key so AssistEdit drilldowns
                // can re-parse without another API hit. Environments are keyed by (Customer No.,
                // Tenant ID, Name), so the cache key must be composite too — keying on Name alone
                // would collide across tenants/customers in a mixed multi-tenant selection.
                // Populated regardless of whether the fetch returned rows — a legitimate empty
                // payload is still a valid cache hit.
                CacheRawResponse(
                    FetchCacheKey(BCEnvironment."Customer No.", BCEnvironment."Tenant ID", BCEnvironment.Name),
                    TempFetchRawResponse);

                if TempFetchBuffer.IsEmpty() then begin
                    TempPlan.Result := TempPlan.Result::Skipped;
                    TempPlan.Reason := CopyStr(NoUpdatesLbl, 1, MaxStrLen(TempPlan.Reason));
                end else begin
                    // Pick a default target version from the fetched candidates.
                    TargetVersion := '';
                    DefaultDate := 0D;
                    ExpectedMonth := 0;
                    ExpectedYear := 0;
                    // The parser returns the winning candidate's REAL availability. We must use
                    // that, not "a date exists": an available version can legitimately carry no
                    // latestSelectableDate (0D), yet it is still Available and must apply via the
                    // released/available branch downstream.
                    AvailableFlag := Parser.PickDefaultTargetVersion(TempFetchBuffer, TargetVersion, DefaultDate, ExpectedMonth, ExpectedYear);

                    TempPlan."Target Version" := TargetVersion;
                    TempPlan."Selected Date" := DefaultDate;
                    TempPlan."Latest Selectable Date" := DefaultDate;
                    TempPlan."Expected Month" := ExpectedMonth;
                    TempPlan."Expected Year" := ExpectedYear;

                    // "Available" reflects the candidate's real availability flag, decoupled from
                    // whether a selectable date was returned.
                    TempPlan.Available := AvailableFlag;

                    // The pre-filled default date is the deadline (Latest Selectable Date). If it is
                    // already in the past it would be rejected by the dialog's date validation
                    // (Selected Date < Today), so a partner accepting defaults would only discover the
                    // failure at the summary. Flag it up-front instead of leaving a silent Pending row.
                    // Mirror the dialog exactly: a 0D default (genuinely available, no selectable date)
                    // is NOT a past date and must stay actionable.
                    if (DefaultDate <> 0D) and (DefaultDate < Today()) then begin
                        TempPlan.Result := TempPlan.Result::Skipped;
                        TempPlan.Reason := CopyStr(StrSubstNo(DefaultDatePastLbl, DefaultDate), 1, MaxStrLen(TempPlan.Reason));
                    end;
                end;
            end;

            TempPlan.Insert(false);
        until BCEnvironment.Next() = 0;
    end;

    /// <summary>
    /// Iterates TempPlan rows where Result = Pending. For each:
    ///  - Publishes OnBeforeApplyReschedule (with a COPY of the row) and a Skip byref.
    ///  - If Skip=true: marks Skipped with 'Skipped by subscriber', continues.
    ///  - Else applies the env directly via AdminAPI.SelectTargetVersion (ApplyEnv), then —
    ///    only on success — durably commits that env's write via the Codeunit.Run sub-operation
    ///    D4P BC Reschedule Apply Step.
    ///  - On success marks Succeeded; on failure marks Failed with the apply's distinctive reason.
    ///  - Publishes OnAfterApplyReschedule (with a COPY of the row) regardless of outcome.
    ///
    /// Why the apply is NOT itself wrapped in Codeunit.Run (regression fix): on a real BC engine
    /// the injected Admin API mock's recorded calls and the apply outcome did not survive a
    /// Codeunit.Run boundary back to this orchestrator, so every env read back as failed/not-applied
    /// (al-runner cannot reproduce this — it lacks real Codeunit.Run isolation). The observable apply
    /// therefore runs here, in the orchestrator's own context, where SelectTargetVersion's return
    /// value, its FailureReason out-param, and the mock's effects are all directly readable.
    ///
    /// Per-env durability (R-C8): the bare Commit() that makes a successful env durable lives in the
    /// Run-invoked D4P BC Reschedule Apply Step, not as a raw Commit in this loop body. Each
    /// successful env commits independently, so the skip-and-continue contract holds — a later env's
    /// failure never rolls back an already-committed earlier env. A failed env never reaches the
    /// commit step. TempPlan is temporary, so its row updates are never the thing being made durable —
    /// only the real D4P BC Environment write is.
    ///
    /// Collected-error handling (R-C7): ApplyEnv runs under ErrorBehavior::Collect, so a hard error
    /// raised inside the apply is captured as a structured ErrorInfo that feeds the row Reason
    /// (preferring the Admin API's distinctive out-param detail) instead of an opaque placeholder.
    /// </summary>
    procedure ApplyPlan(var TempPlan: Record "D4P BC Reschedule Plan Line" temporary)
    var
        TempEventLine: Record "D4P BC Reschedule Plan Line" temporary;
        CommitStep: Codeunit "D4P BC Reschedule Apply Step";
        Skip: Boolean;
        ApplyReason: Text;
    begin
        EnsureAdminAPI();

        TempPlan.Reset();
        TempPlan.SetRange(Result, TempPlan.Result::Pending);
        if not TempPlan.FindSet() then
            // Early-exit: do NOT Reset() here — discarding caller filters would be surprising
            // in the Retry Failed flow. The end-of-procedure Reset() covers the happy path.
            exit;

        repeat
            Skip := false;
            // Hand subscribers a COPY of the current row (R-C9). Record assignment snapshots the
            // field values into a record variable with its own buffer, so a subscriber that
            // navigates the record cannot disturb this loop's live cursor.
            TempEventLine := TempPlan;
            OnBeforeApplyReschedule(TempEventLine, Skip);

            if Skip then begin
                TempPlan.Result := TempPlan.Result::Skipped;
                TempPlan.Reason := CopyStr(SkippedBySubscriberLbl, 1, MaxStrLen(TempPlan.Reason));
            end else begin
                ApplyReason := '';
                if ApplyEnv(TempPlan, ApplyReason) then begin
                    // Apply succeeded for this env. Durably persist its D4P BC Environment write
                    // as an encapsulated atomic unit (R-C8) — no raw Commit in this loop body.
                    CommitStep.Run();
                    TempPlan.Result := TempPlan.Result::Succeeded;
                    TempPlan.Reason := '';
                end else begin
                    // Reason precedence: the Admin API's distinctive detail (or a collected
                    // ErrorInfo) surfaced by ApplyEnv, then a generic placeholder.
                    if ApplyReason = '' then
                        ApplyReason := UnknownErrorLbl;
                    TempPlan.Result := TempPlan.Result::Failed;
                    TempPlan.Reason := CopyStr(ApplyReason, 1, MaxStrLen(TempPlan.Reason));
                end;
            end;

            TempPlan.Modify(false);

            // Publish OnAfter with a fresh COPY reflecting the final outcome (R-C9).
            TempEventLine := TempPlan;
            OnAfterApplyReschedule(TempEventLine);
        until TempPlan.Next() = 0;

        TempPlan.Reset();
    end;

    /// <summary>
    /// Applies one plan row's env directly through the (possibly mocked) Admin API seam and reports
    /// the outcome to the caller — keeping the apply observable to the orchestrator and its tests
    /// (no Codeunit.Run boundary between the mock and this method's reader).
    ///
    /// Runs under ErrorBehavior::Collect (R-C7): a hard error raised during the apply is captured as
    /// a structured ErrorInfo. The FailureReason out-param prefers the Admin API's distinctive
    /// out-param detail, then a collected ErrorInfo message, then a generic fallback (set by the
    /// caller). Performs no Commit — durability is the caller's CommitStep concern.
    /// </summary>
    /// <param name="PlanLine">The plan row whose env should be (re-)applied.</param>
    /// <param name="FailureReason">Out: distinctive failure detail when the apply fails (empty on success).</param>
    /// <returns>true if the env applied successfully; false if it failed.</returns>
    [ErrorBehavior(ErrorBehavior::Collect)]
    local procedure ApplyEnv(var PlanLine: Record "D4P BC Reschedule Plan Line" temporary; var FailureReason: Text): Boolean
    var
        BCEnv: Record "D4P BC Environment";
        CollectedErr: ErrorInfo;
        ApiFailureReason: Text;
        Applied: Boolean;
    begin
        ClearCollectedErrors();
        FailureReason := '';

        // Re-fetch the environment so SelectTargetVersion can Modify it. SetLoadFields constrains
        // reads AND the set available for a subsequent Modify — include every field
        // SelectTargetVersion touches (read or write):
        //   Reads: "Customer No.", "Tenant ID", "Application Family", Name
        //   Writes: "Target Version", "Selected DateTime", "Expected Availability"
        BCEnv.SetLoadFields(
            "Customer No.", "Tenant ID", "Application Family", Name,
            "Target Version", "Selected DateTime", "Expected Availability");
        if not BCEnv.Get(PlanLine."Customer No.", PlanLine."Tenant ID", PlanLine."Environment Name") then begin
            // Environment was deleted between BuildPlan and ApplyPlan (or from the UI mid-run).
            // Emit an explicit, actionable reason instead of an opaque downstream failure.
            FailureReason := StrSubstNo(EnvGoneErr, PlanLine."Environment Name");
            exit(false);
        end;

        Applied := AdminAPI.SelectTargetVersion(
            BCEnv,
            PlanLine."Target Version",
            PlanLine."Selected Date",
            PlanLine."Expected Month",
            PlanLine."Expected Year",
            PlanLine.Available,
            ApiFailureReason);

        if HasCollectedErrors() then begin
            // A hard error was raised inside the apply. Prefer the Admin API's distinctive
            // out-param detail; otherwise feed the structured collected ErrorInfo into the Reason.
            FailureReason := ApiFailureReason;
            if FailureReason = '' then
                foreach CollectedErr in GetCollectedErrors() do
                    if FailureReason = '' then
                        FailureReason := CollectedErr.Message();
            ClearCollectedErrors();
            exit(false);
        end;

        if not Applied then begin
            // Graceful failure (e.g. HTTP non-2xx): SelectTargetVersion returned false carrying
            // the Admin API's distinctive detail in the out-param. Fall back to the generic
            // message only when no detail was supplied.
            FailureReason := ApiFailureReason;
            if FailureReason = '' then
                FailureReason := APIFailureErr;
            exit(false);
        end;

        exit(true);
    end;

    /// <summary>
    /// Runs the summary page for TempPlan. The summary page receives a fresh orchestrator
    /// instance for its Retry Failed action; ApplyPlan calls EnsureAdminAPI() on every
    /// invocation, so a fresh instance re-binds the default Admin API correctly. AL has
    /// no "self" reference for codeunits, hence the local instance. We also forward our
    /// (possibly injected) AdminAPI interface so Retry Failed stays on the same seam.
    /// </summary>
    procedure ShowSummary(var TempPlan: Record "D4P BC Reschedule Plan Line" temporary)
    var
        RetryOrchestrator: Codeunit "D4P BC Bulk Reschedule Mgt";
        SummaryPage: Page "D4P Bulk Reschedule Summary";
    begin
        // Defensive: the summary is a modal UI. If this codeunit is ever invoked from a
        // job queue, API endpoint, or other headless context, skip the page instead of
        // hard-erroring on RunModal. Callers that need headless behavior should consume
        // TempPlan directly.
        if not GuiAllowed() then
            exit;

        EnsureAdminAPI();
        SummaryPage.SetData(TempPlan);
        SummaryPage.SetOrchestrator(RetryOrchestrator);
        SummaryPage.SetAdminAPI(AdminAPI);
        SummaryPage.RunModal();
    end;

    /// <summary>
    /// Publishes before each apply. Subscribers set Skip := true to veto an individual env.
    /// </summary>
    /// <remarks>
    /// The parameter is named <c>TempPlanLine</c> to signal it is a temporary record. AL binds
    /// event-subscriber parameters by name, so every subscriber declares the same
    /// <c>TempPlanLine</c> parameter name. The R-C9 hardening is delivered by the publisher passing
    /// a COPY of the row (see ApplyPlan), so a navigating subscriber cannot disturb the live apply
    /// cursor regardless of the name.
    /// </remarks>
    [IntegrationEvent(false, false)]
    local procedure OnBeforeApplyReschedule(var TempPlanLine: Record "D4P BC Reschedule Plan Line" temporary; var Skip: Boolean)
    begin
    end;

    /// <summary>
    /// Publishes after each apply. For observability / audit sinks.
    /// </summary>
    /// <remarks>Parameter name <c>TempPlanLine</c> shared with subscriber binding — see OnBeforeApplyReschedule.</remarks>
    [IntegrationEvent(false, false)]
    local procedure OnAfterApplyReschedule(var TempPlanLine: Record "D4P BC Reschedule Plan Line" temporary)
    begin
    end;

    /// <summary>
    /// [TryFunction] wrapper around AdminAPI.GetAvailableUpdates. Stages the result
    /// in TempFetchBuffer because AL forbids passing a var Record param into a TryFunction's
    /// own var param together with an interface invocation.
    /// </summary>
    [TryFunction]
    local procedure TryFetchUpdates(var BCEnvironment: Record "D4P BC Environment")
    begin
        AdminAPI.GetAvailableUpdates(BCEnvironment, TempFetchBuffer, TempFetchRawResponse);
    end;

    local procedure ClearFetchBuffer()
    begin
        TempFetchBuffer.Reset();
        TempFetchBuffer.DeleteAll(false);
        TempFetchRawResponse := '';
    end;

    /// <summary>
    /// Builds the composite cache key for an environment. Environments are keyed by
    /// (Customer No., Tenant ID, Name); the dialog (page 62035) builds the SAME key when
    /// reading the cache, so the format MUST stay in lockstep between the two objects.
    /// </summary>
    procedure FetchCacheKey(CustomerNo: Code[20]; TenantID: Guid; EnvName: Text): Text
    begin
        exit(StrSubstNo('%1|%2|%3', CustomerNo, TenantID, EnvName));
    end;

    /// <summary>
    /// Stage a raw-JSON payload for an env into the per-run cache, keyed by the composite
    /// FetchCacheKey. Later handed to the dialog via GetFetchCache so AssistEdit can
    /// re-parse without re-hitting the API.
    /// </summary>
    local procedure CacheRawResponse(CacheKey: Text; RawResponse: Text)
    begin
        if FetchCache.ContainsKey(CacheKey) then
            FetchCache.Set(CacheKey, RawResponse)
        else
            FetchCache.Add(CacheKey, RawResponse);
    end;

    /// <summary>
    /// Hand the per-env raw-JSON cache built during BuildPlan to the caller so it can
    /// forward it into the dialog (SetFetchCache) and avoid AssistEdit re-fetches.
    /// </summary>
    procedure GetFetchCache(var TargetCache: Dictionary of [Text, Text])
    begin
        TargetCache := FetchCache;
    end;

    /// <summary>
    /// (Bug C2) Returns true iff the plan contains at least one fetch-failure Skipped row — a row
    /// whose Reason was stamped by BuildPlan with the shared "Fetch failed: ..." prefix. Lets
    /// RunBulkReschedule distinguish an all-fetch-failed run (which must surface the per-env reasons)
    /// from a genuine no-updates run (which shows NothingToRescheduleMsg). A genuine "No updates
    /// available" Skipped row does NOT match. Scans a copy so the caller's position/filters are intact.
    /// </summary>
    procedure AnyFetchFailure(var TempPlan: Record "D4P BC Reschedule Plan Line" temporary): Boolean
    var
        TempScan: Record "D4P BC Reschedule Plan Line" temporary;
        FetchFailedPrefix: Text;
    begin
        // Derive the prefix from the same label BuildPlan stamps — no magic string to drift.
        FetchFailedPrefix := StrSubstNo(FetchFailedReasonLbl, '');

        TempScan.Copy(TempPlan, true);
        TempScan.Reset();
        TempScan.SetRange(Result, TempScan.Result::Skipped);
        if TempScan.FindSet() then
            repeat
                if StrPos(TempScan.Reason, FetchFailedPrefix) = 1 then
                    exit(true);
            until TempScan.Next() = 0;

        exit(false);
    end;

    /// <summary>
    /// If no mock/impl was injected, bind AdminAPI to the default D4P BC Admin API codeunit.
    /// </summary>
    local procedure EnsureAdminAPI()
    var
        DefaultImpl: Codeunit "D4P BC Admin API";
    begin
        if AdminAPIInjected then
            exit;

        AdminAPI := DefaultImpl;
        AdminAPIInjected := true;
    end;
}
