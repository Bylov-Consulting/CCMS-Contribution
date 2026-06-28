namespace D4P.CCMS.Environment;

table 62026 "D4P BC Reschedule Plan Line"
{
    Caption = 'BC Reschedule Plan Line';
    TableType = Temporary;

    fields
    {
        field(1; "Entry No."; Integer)
        {
            Caption = 'Entry No.';
            DataClassification = CustomerContent;
        }
        field(10; "Customer No."; Code[20])
        {
            Caption = 'Customer No.';
            DataClassification = CustomerContent;
        }
        field(20; "Tenant ID"; Guid)
        {
            Caption = 'Tenant ID';
            DataClassification = CustomerContent;
        }
        field(30; "Environment Name"; Text[30])
        {
            Caption = 'Environment Name';
            DataClassification = CustomerContent;
        }
        field(40; "Application Family"; Text[50])
        {
            Caption = 'Application Family';
            DataClassification = CustomerContent;
        }
        field(50; "Current Version"; Text[100])
        {
            Caption = 'Current Version';
            DataClassification = CustomerContent;
        }
        field(60; "Target Version"; Text[100])
        {
            Caption = 'Target Version';
            DataClassification = CustomerContent;
            Editable = true;
        }
        field(70; "Selected Date"; Date)
        {
            Caption = 'Selected Date';
            DataClassification = CustomerContent;
            Editable = true;
        }
        field(80; "Latest Selectable Date"; Date)
        {
            Caption = 'Latest Selectable Date';
            DataClassification = CustomerContent;
            Editable = false;
        }
        field(90; "Expected Month"; Integer)
        {
            Caption = 'Expected Month';
            DataClassification = CustomerContent;
            Editable = false;
        }
        field(100; "Expected Year"; Integer)
        {
            Caption = 'Expected Year';
            DataClassification = CustomerContent;
            Editable = false;
        }
        field(110; Available; Boolean)
        {
            Caption = 'Available';
            DataClassification = CustomerContent;
            Editable = false;
        }
        field(120; Result; Enum "D4P Reschedule Result")
        {
            Caption = 'Result';
            DataClassification = CustomerContent;
            Editable = false;
        }
        field(130; Reason; Text[250])
        {
            Caption = 'Reason';
            DataClassification = CustomerContent;
            Editable = false;
        }
    }

    keys
    {
        key(PK; "Entry No.")
        {
            Clustered = true;
        }
    }
}
