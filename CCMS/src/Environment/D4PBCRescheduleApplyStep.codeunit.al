namespace D4P.CCMS.Environment;

/// <summary>
/// Atomic per-environment durability sub-operation (PR #5 R-C8). The orchestrator
/// (<see cref="Codeunit::D4P BC Bulk Reschedule Mgt"/>) performs the observable Admin API
/// apply itself — directly through the (possibly mocked) <c>D4P IBC Admin API</c> seam, so the
/// apply result and the mock's recorded calls stay visible to the orchestrator and its tests —
/// and then, only once an env has applied successfully, invokes this step through
/// <c>Codeunit.Run</c> to durably persist that env's <c>D4P BC Environment</c> write.
///
/// Why a step instead of a raw <c>Commit()</c> (R-C8 intent): the per-env <c>Commit</c> that
/// makes a successful apply durable lives here, inside a <c>Codeunit.Run</c>-invoked OnRun,
/// rather than as a bare <c>Commit()</c> statement in the orchestrator's ApplyPlan loop body.
/// Each successful env is committed independently, so the skip-and-continue contract holds: a
/// later env's failure can never roll back an already-committed earlier env. A failed env never
/// reaches this step (the orchestrator only runs it on success), so no failed write is ever made
/// durable.
///
/// NOTE on the earlier R-C8 shape: a prior revision ran the *whole* apply (including
/// <c>AdminAPI.SelectTargetVersion</c>) inside this step's OnRun and read the outcome back via the
/// step's global variables. On a real BC engine that broke every apply-path test — the injected
/// mock's effects and the apply outcome did not survive the <c>Codeunit.Run</c> boundary as the
/// orchestrator expected, so every env was treated as failed/not-applied. Keeping the observable
/// apply in the orchestrator and narrowing this step to the genuinely-durable write fixes that
/// while preserving R-C8's "durable per-env, no raw Commit in the loop" intent.
/// </summary>
codeunit 62008 "D4P BC Reschedule Apply Step"
{
    trigger OnRun()
    begin
        // Make the orchestrator's just-applied D4P BC Environment write durable for this env.
        // Encapsulated here (R-C8) so the ApplyPlan loop body contains no raw Commit().
        Commit();
    end;
}
