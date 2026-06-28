namespace D4P.CCMS.Environment;

/// <summary>
/// Phase-4 end-of-run summary. Displays the post-apply plan, counts outcomes
/// in the caption, and offers Retry Failed / Copy to Clipboard / Close.
/// Retry Failed delegates back through a caller-supplied orchestrator reference.
/// </summary>
page 62033 "D4P Bulk Reschedule Summary"
{
    ApplicationArea = All;
    Caption = 'Bulk Reschedule Complete';
    PageType = List;
    SourceTable = "D4P BC Reschedule Plan Line";
    SourceTableTemporary = true;
    Editable = false;
    InsertAllowed = false;
    DeleteAllowed = false;
    ModifyAllowed = false;

    layout
    {
        area(Content)
        {
            repeater(Summary)
            {
                Caption = 'Summary';
                field("Environment Name"; Rec."Environment Name")
                {
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the environment name.';
                }
                field("Customer No."; Rec."Customer No.")
                {
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the customer number that owns the environment.';
                }
                field("Target Version"; Rec."Target Version")
                {
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the target version that was scheduled.';
                }
                field("Selected Date"; Rec."Selected Date")
                {
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the date the update was scheduled for.';
                }
                field("Expected Month"; Rec."Expected Month")
                {
                    Visible = ExpectedColumnsVisible;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the expected release month for unreleased target versions.';
                }
                field("Expected Year"; Rec."Expected Year")
                {
                    Visible = ExpectedColumnsVisible;
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the expected release year for unreleased target versions.';
                }
                field(Result; Rec.Result)
                {
                    StyleExpr = ResultStyleExpr;
                    ToolTip = 'Specifies the final outcome for this environment.';
                }
                field(Reason; Rec.Reason)
                {
                    StyleExpr = RowStyleExpr;
                    ToolTip = 'Specifies the reason this environment was Skipped or Failed, if any.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(RetryFailed)
            {
                ApplicationArea = All;
                Caption = 'Retry Failed';
                Image = Reuse;
                ToolTip = 'Re-apply the plan for environments that failed. Succeeded and Skipped rows are left untouched.';

                trigger OnAction()
                begin
                    RetryFailedRows();
                end;
            }
            action(CopyToClipboard)
            {
                ApplicationArea = All;
                Caption = 'Copy to Clipboard';
                Image = Copy;
                ToolTip = 'Copy the summary as TSV for pasting into a ticket or email.';

                trigger OnAction()
                begin
                    CopySummaryToClipboard();
                end;
            }
            action(CloseAction)
            {
                ApplicationArea = All;
                Caption = 'Close';
                Image = Close;
                ToolTip = 'Close the summary.';

                trigger OnAction()
                begin
                    CurrPage.Close();
                end;
            }
        }
        area(Promoted)
        {
            group(Category_Process)
            {
                Caption = 'Process';
                actionref(RetryFailedPromoted; RetryFailed) { }
                actionref(CopyToClipboardPromoted; CopyToClipboard) { }
            }
        }
    }

    var
        OrchestratorRef: Codeunit "D4P BC Bulk Reschedule Mgt";
        AdminAPI: Interface "D4P IBC Admin API";
        OrchestratorSet: Boolean;
        AdminAPIInjected: Boolean;
        ExpectedColumnsVisible: Boolean;
        RowStyleExpr: Text;
        ResultStyleExpr: Text;
        CaptionLbl: Label 'Bulk Reschedule Complete — %1 Succeeded, %2 Skipped, %3 Failed', Comment = '%1 Succeeded count, %2 Skipped count, %3 Failed count';
        NothingToRetryMsg: Label 'There are no failed rows to retry.';
        ClipboardFallbackMsg: Label 'Summary (copy from this message):\%1', Comment = '%1 = TSV payload';
        OrchestratorMissingErr: Label 'Retry is not available because the summary was opened without an orchestrator reference.';

    trigger OnOpenPage()
    begin
        RefreshCaption();
    end;

    trigger OnAfterGetRecord()
    begin
        UpdateRowStyle();
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
    /// Wire the orchestrator the summary delegates to for Retry Failed. Must be called
    /// before RunModal by the codeunit that built the plan.
    /// </summary>
    procedure SetOrchestrator(var NewOrchestrator: Codeunit "D4P BC Bulk Reschedule Mgt")
    begin
        OrchestratorRef := NewOrchestrator;
        OrchestratorSet := true;
    end;

    /// <summary>
    /// Test seam: injects a custom API implementation. Intended for CCMS.Test only.
    /// In production, the default <see cref="Codeunit::D4P BC Admin API"/> is used
    /// automatically via <c>EnsureAdminAPI</c>. Calling this from a non-test context
    /// is supported but semantically risky — a non-authenticating or mis-routed
    /// implementation would be used for every subsequent API call in this session.
    /// </summary>
    /// <param name="NewAPI">The implementation to use for all subsequent API calls.</param>
    /// <remarks>
    /// AL's codeunit-by-value semantics mean the orchestrator we were given via
    /// SetOrchestrator is a COPY — we therefore store the interface and re-apply it to
    /// that copy just before ApplyPlan so the copy's AdminAPI matches the caller's.
    /// </remarks>
    procedure SetAdminAPI(NewAPI: Interface "D4P IBC Admin API")
    begin
        AdminAPI := NewAPI;
        AdminAPIInjected := true;
    end;

    local procedure RetryFailedRows()
    var
        AnyFailed: Boolean;
    begin
        if not OrchestratorSet then
            Error(OrchestratorMissingErr);

        Rec.Reset();
        Rec.SetRange(Result, Rec.Result::Failed);
        // Rec is a temporary SourceTable — the update-lock hint on FindSet is ignored
        // for temp tables and only serves to mislead readers, so drop it.
        if not Rec.FindSet() then begin
            Rec.Reset();
            Message(NothingToRetryMsg);
            exit;
        end;

        repeat
            AnyFailed := true;
            Rec.Result := Rec.Result::Pending;
            Rec.Reason := '';
            Rec.Modify(false);
        until Rec.Next() = 0;
        Rec.Reset();

        if AnyFailed then begin
            // Re-apply the injected Admin API onto our orchestrator copy so Retry Failed
            // hits the caller's interface (including any test mock). Done here rather than
            // in SetAdminAPI so the two wiring calls are order-independent, and so a
            // second Retry re-applies the interface after the orchestrator's internal state
            // has been mutated by the previous ApplyPlan.
            if AdminAPIInjected then
                OrchestratorRef.SetAdminAPI(AdminAPI);
            OrchestratorRef.ApplyPlan(Rec);
        end;

        CurrPage.Update(false);
        RefreshCaption();
    end;

    local procedure CopySummaryToClipboard()
    var
        TsvBuilder: TextBuilder;
        Tab: Char;
    begin
        Tab := 9; // ASCII horizontal tab
        TsvBuilder.Append('Environment');
        TsvBuilder.Append(Tab);
        TsvBuilder.Append('Version');
        TsvBuilder.Append(Tab);
        TsvBuilder.Append('Date');
        TsvBuilder.Append(Tab);
        TsvBuilder.Append('Result');
        TsvBuilder.Append(Tab);
        TsvBuilder.AppendLine('Reason');

        Rec.Reset();
        if Rec.FindSet() then
            repeat
                TsvBuilder.Append(Rec."Environment Name");
                TsvBuilder.Append(Tab);
                TsvBuilder.Append(Rec."Target Version");
                TsvBuilder.Append(Tab);
                TsvBuilder.Append(Format(Rec."Selected Date"));
                TsvBuilder.Append(Tab);
                TsvBuilder.Append(Format(Rec.Result));
                TsvBuilder.Append(Tab);
                TsvBuilder.AppendLine(Rec.Reason);
            until Rec.Next() = 0;
        Rec.Reset();

        // BC 27 has no public AL clipboard API available without AppSource platform extensions.
        // Per solution-plan §6 the documented fallback is to surface the TSV in a Message()
        // so the partner can select-and-copy for ticketing.
        Message(ClipboardFallbackMsg, TsvBuilder.ToText());
    end;

    local procedure RefreshCaption()
    var
        TempCountFilter: Record "D4P BC Reschedule Plan Line" temporary;
        SucceededCount: Integer;
        SkippedCount: Integer;
        FailedCount: Integer;
    begin
        // Single-pass counter: previously three SetRange + Count() passes walked the
        // temp table three times. One FindSet + case is both cheaper and easier to read.
        // NOTE: no else branch — Result is Extensible, so Pending (or any future
        // partner-added value) must fall through silently. Counting them in one of the
        // three buckets would be wrong.
        TempCountFilter.Copy(Rec, true);
        TempCountFilter.Reset();
        if TempCountFilter.FindSet() then
            repeat
                case TempCountFilter.Result of
                    TempCountFilter.Result::Succeeded:
                        SucceededCount += 1;
                    TempCountFilter.Result::Skipped:
                        SkippedCount += 1;
                    TempCountFilter.Result::Failed:
                        FailedCount += 1;
                end;
            until TempCountFilter.Next() = 0;

        CurrPage.Caption := StrSubstNo(CaptionLbl, SucceededCount, SkippedCount, FailedCount);
    end;

    local procedure UpdateRowStyle()
    begin
        case Rec.Result of
            Rec.Result::Succeeded:
                begin
                    RowStyleExpr := Format(PageStyle::Favorable);
                    ResultStyleExpr := Format(PageStyle::Favorable);
                end;
            Rec.Result::Skipped:
                begin
                    RowStyleExpr := Format(PageStyle::Ambiguous);
                    ResultStyleExpr := Format(PageStyle::Ambiguous);
                end;
            Rec.Result::Failed:
                begin
                    RowStyleExpr := Format(PageStyle::Unfavorable);
                    ResultStyleExpr := Format(PageStyle::Unfavorable);
                end;
            else begin
                RowStyleExpr := Format(PageStyle::Standard);
                ResultStyleExpr := Format(PageStyle::Standard);
            end;
        end;
    end;
}
