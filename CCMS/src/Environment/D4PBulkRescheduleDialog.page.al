namespace D4P.CCMS.Environment;

/// <summary>
/// Phase-2 dialog of the bulk-reschedule flow. Presents one row per selected
/// environment, with inline edit of Target Version (AssistEdit drilldown to
/// page 62025) and Selected Date. Accept/Cancel exposed via WasAccepted()
/// after RunModal.
///
/// PageType = List (not StandardDialog because StandardDialog with a repeater
/// raises AW0008; not ConfigurationDialog because it does not render a
/// repeater body at runtime in the BC 28 Web Client even though it compiles).
/// The OK action is promoted to the ribbon so it is a big visible button
/// without forcing users to open the Actions dropdown.
/// </summary>
page 62035 "D4P Bulk Reschedule Dialog"
{
    ApplicationArea = All;
    Caption = 'Bulk Reschedule Updates';
    PageType = List;
    SourceTable = "D4P BC Reschedule Plan Line";
    SourceTableTemporary = true;
    Editable = true;
    InsertAllowed = false;
    DeleteAllowed = false;
    ModifyAllowed = true;

    layout
    {
        area(Content)
        {
            repeater(Plan)
            {
                Caption = 'Plan';
                field("Environment Name"; Rec."Environment Name")
                {
                    Editable = false;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the environment name.';
                }
                field("Customer No."; Rec."Customer No.")
                {
                    Editable = false;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the customer number that owns the environment.';
                }
                field("Current Version"; Rec."Current Version")
                {
                    Editable = false;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the environment''s current version.';
                }
                field("Target Version"; Rec."Target Version")
                {
                    Editable = RowEditable;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the target version to schedule. Choose from the AssistEdit to see all updates available for this environment.';

                    trigger OnAssistEdit()
                    begin
                        PickTargetVersion();
                    end;
                }
                field("Selected Date"; Rec."Selected Date")
                {
                    Editable = RowEditable;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the date to apply the update (between today and the latest selectable date).';

                    trigger OnValidate()
                    begin
                        ValidateSelectedDate();
                    end;
                }
                field("Latest Selectable Date"; Rec."Latest Selectable Date")
                {
                    Editable = false;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the latest date on which this environment can accept the target version.';
                }
                field("Expected Month"; Rec."Expected Month")
                {
                    Editable = false;
                    Visible = ExpectedColumnsVisible;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the expected release month when the target version is unreleased.';
                }
                field("Expected Year"; Rec."Expected Year")
                {
                    Editable = false;
                    Visible = ExpectedColumnsVisible;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the expected release year when the target version is unreleased.';
                }
                field(Result; Rec.Result)
                {
                    Editable = false;
                    StyleExpr = ResultStyleExpr;
                    ToolTip = 'Specifies the current result state for this environment.';
                }
                field(Reason; Rec.Reason)
                {
                    Editable = false;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the reason this environment is Skipped or Failed, if any.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(OK)
            {
                ApplicationArea = All;
                Caption = 'OK';
                Image = Approve;
                InFooterBar = true;
                ToolTip = 'Accept the plan and apply the reschedule to the listed environments.';

                trigger OnAction()
                begin
                    Accepted := true;
                    CurrPage.Close();
                end;
            }
            action(CancelAction)
            {
                ApplicationArea = All;
                Caption = 'Cancel';
                Image = Cancel;
                InFooterBar = true;
                ToolTip = 'Discard the plan and exit without applying any reschedule.';

                trigger OnAction()
                begin
                    Accepted := false;
                    CurrPage.Close();
                end;
            }
        }
        area(Promoted)
        {
            group(Category_Process)
            {
                Caption = 'Process';

                actionref(OKPromoted; OK)
                {
                }
            }
        }
    }

    var
        AdminAPI: Interface "D4P IBC Admin API";
        AdminAPIInjected: Boolean;
        // Per-env raw-JSON cache warmed by the orchestrator after BuildPlan. On AssistEdit
        // the dialog prefers a parse-of-cached-JSON over a re-fetch. Missing keys fall back
        // to a live fetch (e.g. a row that originated as a fetch failure never hit the cache).
        FetchCache: Dictionary of [Text, Text];
        Accepted: Boolean;
        RowEditable: Boolean;
        ExpectedColumnsVisible: Boolean;
        RowStyleExpr: Text;
        ResultStyleExpr: Text;
        NoUpdatesAvailableErr: Label 'No updates are available for environment %1.', Comment = '%1 = Environment Name';
        EnvMissingErr: Label 'Environment %1 no longer exists in the local database. Refresh the environment list and try again.', Comment = '%1 = Environment Name';
        DateTooEarlyErr: Label 'Selected date cannot be earlier than today.';
        DateTooLateErr: Label 'Selected date cannot be later than %1.', Comment = '%1 = Latest selectable date';

    trigger OnAfterGetRecord()
    begin
        // OnAfterGetRecord fires per row during rendering and is sufficient to keep
        // RowStyleExpr/RowEditable in sync. OnAfterGetCurrRecord was previously calling
        // UpdateRowState() too, which duplicated the work on every cursor move.
        UpdateRowState();
    end;

    /// <summary>
    /// Copy caller-provided plan rows into the page's temporary record. Called before RunModal.
    /// </summary>
    procedure SetData(var TempSourcePlan: Record "D4P BC Reschedule Plan Line" temporary)
    begin
        Rec.Reset();
        Rec.DeleteAll(false);

        // Page-level column visibility: show the Expected Month/Year columns when ANY row
        // is unreleased. A column-level "Visible = not Rec.Available" expression is evaluated
        // against a single row and hides the column for the entire grid, so a mixed plan lost
        // those columns. Reflect the whole plan in a page variable instead.
        ExpectedColumnsVisible := false;

        TempSourcePlan.Reset();
        if TempSourcePlan.FindSet() then
            repeat
                Rec := TempSourcePlan;
                Rec.Insert(false);
                if not TempSourcePlan.Available then
                    ExpectedColumnsVisible := true;
            until TempSourcePlan.Next() = 0;
    end;

    /// <summary>
    /// Copy the page's (possibly user-edited) plan rows back into the caller's temp record.
    /// Called after RunModal when WasAccepted() is true.
    /// </summary>
    procedure GetData(var TempTargetPlan: Record "D4P BC Reschedule Plan Line" temporary)
    begin
        TempTargetPlan.Reset();
        TempTargetPlan.DeleteAll(false);

        Rec.Reset();
        if Rec.FindSet() then
            repeat
                TempTargetPlan := Rec;
                TempTargetPlan.Insert(false);
            until Rec.Next() = 0;
    end;

    /// <summary>
    /// Returns true if the user clicked OK (accepted the plan). Callers check this
    /// after RunModal instead of Action::OK because PageType = List exposes neither.
    /// </summary>
    procedure WasAccepted(): Boolean
    begin
        exit(Accepted);
    end;

    local procedure UpdateRowState()
    begin
        // Pending rows are editable (user can still pick a different version or date).
        // Succeeded / Skipped / Failed rows are locked and styled.
        RowEditable := Rec.Result = Rec.Result::Pending;

        case Rec.Result of
            Rec.Result::Pending:
                RowStyleExpr := Format(PageStyle::Standard);
            Rec.Result::Succeeded:
                RowStyleExpr := Format(PageStyle::Favorable);
            Rec.Result::Skipped,
            Rec.Result::Failed:
                RowStyleExpr := Format(PageStyle::Unfavorable);
        end;

        // Result column gets stronger styling so the state is scannable at a glance.
        case Rec.Result of
            Rec.Result::Succeeded:
                ResultStyleExpr := Format(PageStyle::Favorable);
            Rec.Result::Skipped,
            Rec.Result::Failed:
                ResultStyleExpr := Format(PageStyle::Unfavorable);
            else
                ResultStyleExpr := Format(PageStyle::Standard);
        end;
    end;

    local procedure ValidateSelectedDate()
    begin
        if Rec."Selected Date" = 0D then
            exit;

        if Rec."Selected Date" < Today() then
            Error(DateTooEarlyErr);

        if (Rec."Latest Selectable Date" <> 0D) and (Rec."Selected Date" > Rec."Latest Selectable Date") then
            Error(DateTooLateErr, Rec."Latest Selectable Date");
    end;

    /// <summary>
    /// Test seam: injects a custom API implementation. Intended for CCMS.Test only.
    /// In production, the default <see cref="Codeunit::D4P BC Admin API"/> is used
    /// automatically via <c>EnsureAdminAPI</c>. Calling this from a non-test context
    /// is supported but semantically risky — a non-authenticating or mis-routed
    /// implementation would be used for every subsequent API call in this session.
    /// </summary>
    /// <param name="NewAPI">The implementation to use for all subsequent API calls.</param>
    procedure SetAdminAPI(NewAPI: Interface "D4P IBC Admin API")
    begin
        AdminAPI := NewAPI;
        AdminAPIInjected := true;
    end;

    /// <summary>
    /// Warm the dialog's per-env raw-JSON cache with payloads already fetched during
    /// BuildPlan. AssistEdit drilldowns check this cache first and only re-fetch when a
    /// key is missing (e.g. for a row whose original fetch failed).
    /// </summary>
    /// <param name="SourceCache">Source dictionary keyed by environment name; copied by value.</param>
    procedure SetFetchCache(SourceCache: Dictionary of [Text, Text])
    begin
        FetchCache := SourceCache;
    end;

    /// <summary>
    /// If no implementation was injected via SetAdminAPI, bind AdminAPI to the default
    /// D4P BC Admin API codeunit on first use.
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

    /// <summary>
    /// AssistEdit handler for Target Version — prefers the per-env raw-JSON cache warmed
    /// by the orchestrator (so a click-to-drilldown is free) and only calls the Admin API
    /// on cache miss (e.g. the original fetch failed). Opens page 62025 for selection and
    /// writes the user's choice back on OK.
    /// </summary>
    local procedure PickTargetVersion()
    var
        BCEnv: Record "D4P BC Environment";
        TempAvailableUpdate: Record "D4P BC Available Update" temporary;
        Parser: Codeunit "D4P BC Update Parser";
        BulkRescheduleMgt: Codeunit "D4P BC Bulk Reschedule Mgt";
        UpdateSelectionDialog: Page "D4P Update Selection Dialog";
        CachedJson: Text;
        RawResponse: Text;
        TargetVersion: Text[100];
        SelectedDate: Date;
        LatestSelectableDate: Date;
        ExpectedMonth: Integer;
        ExpectedYear: Integer;
    begin
        if Rec.Result <> Rec.Result::Pending then
            exit;

        // Cache-hit path: skip the API entirely and re-parse the JSON we already have.
        // The cache is keyed by the env's full composite key (Customer No. + Tenant ID +
        // Environment Name) — keying on Environment Name alone would collide across tenants
        // in a mixed multi-tenant selection. Build the key via the orchestrator's helper so
        // the format stays in lockstep with how the cache was populated during BuildPlan.
        // An empty cached JSON means "we fetched and got nothing" — treat that the same
        // as a live fetch that returned zero rows (Error below), rather than falling
        // through to a second API call.
        if FetchCache.Get(BulkRescheduleMgt.FetchCacheKey(Rec."Customer No.", Rec."Tenant ID", Rec."Environment Name"), CachedJson) then begin
            if CachedJson <> '' then
                Parser.ParseUpdatesJson(CachedJson, TempAvailableUpdate);
        end else begin
            // Only these four fields are consumed downstream: the first two are the key,
            // Application Family + Name are used by AdminAPI.GetAvailableUpdates to build
            // the endpoint path; the inner BCTenant.Get is narrowed separately.
            BCEnv.SetLoadFields("Customer No.", "Tenant ID", "Application Family", Name);
            if not BCEnv.Get(Rec."Customer No.", Rec."Tenant ID", Rec."Environment Name") then begin
                // The environment was deleted/renamed between BuildPlan and this drilldown.
                // Previously this silently exited, leaving the partner staring at an AssistEdit
                // that did nothing. Surface it so they know the row is stale.
                Error(EnvMissingErr, Rec."Environment Name");
            end;

            EnsureAdminAPI();
            AdminAPI.GetAvailableUpdates(BCEnv, TempAvailableUpdate, RawResponse);
        end;

        if TempAvailableUpdate.IsEmpty() then
            Error(NoUpdatesAvailableErr, Rec."Environment Name");

        UpdateSelectionDialog.SetData(TempAvailableUpdate);
        if UpdateSelectionDialog.RunModal() <> Action::OK then
            exit;

        UpdateSelectionDialog.GetSelectedVersion(TargetVersion, SelectedDate, ExpectedMonth, ExpectedYear);
        LatestSelectableDate := UpdateSelectionDialog.GetLatestSelectableDate();

        Rec."Target Version" := TargetVersion;
        Rec."Selected Date" := SelectedDate;
        Rec."Expected Month" := ExpectedMonth;
        Rec."Expected Year" := ExpectedYear;
        Rec.Available := (SelectedDate <> 0D);
        // Preserve the picked row's real upper bound so the date-validation OnValidate
        // keeps its cap. Previously this wrote SelectedDate here, which removed the
        // upper bound and let partners schedule past the API deadline.
        Rec."Latest Selectable Date" := LatestSelectableDate;
        Rec.Modify(false);
        CurrPage.Update(false);
    end;
}
