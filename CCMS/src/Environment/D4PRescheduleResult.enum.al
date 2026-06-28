namespace D4P.CCMS.Environment;

enum 62007 "D4P Reschedule Result"
{
    Extensible = true;

    value(0; Pending)
    {
        Caption = 'Pending';
    }
    value(1; Succeeded)
    {
        Caption = 'Succeeded';
    }
    value(2; Skipped)
    {
        Caption = 'Skipped';
    }
    value(3; Failed)
    {
        Caption = 'Failed';
    }
}
