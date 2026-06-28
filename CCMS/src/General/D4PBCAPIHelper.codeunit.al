namespace D4P.CCMS.General;

using D4P.CCMS.Setup;
using D4P.CCMS.Tenant;
using System.Security.Authentication;

codeunit 62049 "D4P BC API Helper"
{
    // SingleInstance so the per-tenant OAuth token cache (see GetOAuthToken) survives across
    // the many short-lived APIHelper variables the module instantiates, letting a still-valid
    // token be reused for the whole session instead of re-acquired on every request.
    SingleInstance = true;

    var
        // Cached client-credential tokens keyed by "<tenant id>|<client id>", with the parallel
        // expiry map below. Reused until shortly before expiry; SecretText keeps the token opaque.
        CachedTokens: Dictionary of [Text, SecretText];
        CachedTokenExpiry: Dictionary of [Text, DateTime];

    procedure SendAdminAPIRequest(var BCTenant: Record "D4P BC Tenant"; Method: Text; Endpoint: Text; RequestBody: Text; var ResponseText: Text): Boolean
    var
        HttpClient: HttpClient;
        RequestContent: HttpContent;
        Headers: HttpHeaders;
        HttpRequestMessage: HttpRequestMessage;
        HttpResponseMessage: HttpResponseMessage;
        FailedToObtainTokenErr: Label 'Failed to obtain access token for tenant %1.', Comment = '%1 - Tenant identifier';
        FailedToSendRequestErr: Label 'Failed to send HTTP request';
        AuthToken: SecretText;
        EndpointUrl: Text;
    begin
        // Get OAuth token
        AuthToken := GetOAuthToken(BCTenant);
        if AuthToken.IsEmpty() then
            Error(FailedToObtainTokenErr, BCTenant."Tenant ID".ToText().Replace('{', '').Replace('}', ''));

        // Build full endpoint URL
        EndpointUrl := GetAdminAPIBaseUrl() + Endpoint;

        // Initialize the HTTP request
        HttpRequestMessage.SetRequestUri(EndpointUrl);
        HttpRequestMessage.Method := Method;
        HttpRequestMessage.GetHeaders(Headers);
        Headers.Add('Authorization', SecretStrSubstNo('Bearer %1', AuthToken));

        // Add request body if provided
        if RequestBody <> '' then begin
            RequestContent.WriteFrom(RequestBody);
            RequestContent.GetHeaders(Headers);
            Headers.Remove('Content-Type');
            Headers.Add('Content-Type', 'application/json');
            HttpRequestMessage.Content := RequestContent;
        end;

        // Send the request
        if not HttpClient.Send(HttpRequestMessage, HttpResponseMessage) then
            Error(FailedToSendRequestErr);

        HttpResponseMessage.Content().ReadAs(ResponseText);
        ShowDebugMessage(ResponseText, Method + ' ' + Endpoint);

        exit(HttpResponseMessage.IsSuccessStatusCode());
    end;

    procedure SendAutomationAPIRequest(AADTenantId: Guid; EnvironmentName: Text; Method: Text; Endpoint: Text; RequestBody: Text; AuthToken: SecretText; var ResponseText: Text): Boolean
    var
        HttpClient: HttpClient;
        RequestContent: HttpContent;
        Headers: HttpHeaders;
        HttpRequestMessage: HttpRequestMessage;
        HttpResponseMessage: HttpResponseMessage;
        FailedToConnectErr: Label 'Failed to connect to the API.';
        EndpointUrl: Text;
        TenantIdText: Text;
    begin
        // Format tenant ID (remove braces)
        TenantIdText := Format(AADTenantId);
        TenantIdText := DelChr(TenantIdText, '=', '{}');

        // Build full endpoint URL
        EndpointUrl := StrSubstNo('%1/%2/%3%4',
            GetAutomationAPIBaseUrl(),
            TenantIdText,
            EnvironmentName,
            Endpoint);

        // Initialize the HTTP request
        HttpRequestMessage.SetRequestUri(EndpointUrl);
        HttpRequestMessage.Method := Method;
        HttpRequestMessage.GetHeaders(Headers);
        Headers.Add('Authorization', SecretStrSubstNo('Bearer %1', AuthToken));
        Headers.Add('Accept', 'application/json');

        // Add request body if provided
        if RequestBody <> '' then begin
            RequestContent.WriteFrom(RequestBody);
            RequestContent.GetHeaders(Headers);
            Headers.Remove('Content-Type');
            Headers.Add('Content-Type', 'application/json');
            HttpRequestMessage.Content := RequestContent;
        end;

        // Send the request
        if not HttpClient.Send(HttpRequestMessage, HttpResponseMessage) then
            Error(FailedToConnectErr);

        HttpResponseMessage.Content().ReadAs(ResponseText);
        ShowDebugMessage(ResponseText, Method + ' ' + Endpoint);

        exit(HttpResponseMessage.IsSuccessStatusCode());
    end;

    procedure GetOAuthToken(var BCTenant: Record "D4P BC Tenant") AuthToken: SecretText
    var
        OAuth2: Codeunit OAuth2;
        FailedToGetTokenErr: Label 'Failed to get access token from response\%1', Comment = '%1 = Error response';
        Scopes: List of [Text];
        ClientSecret: SecretText;
        AccessTokenURL: Text;
        tenantID: Text;
        CacheKey: Text;
    begin
        tenantID := BCTenant."Tenant ID".ToText().Replace('{', '');
        tenantID := tenantID.Replace('}', '');

        // Reuse a still-valid cached token for this tenant/client instead of re-acquiring on
        // every request; only fall through to Azure AD when the token is missing or near expiry.
        CacheKey := tenantID + '|' + Format(BCTenant."Client ID");
        if TryGetCachedToken(CacheKey, AuthToken) then
            exit;

        AccessTokenURL := 'https://login.microsoftonline.com/' + tenantID + '/oauth2/v2.0/token';
        Scopes.Add('https://api.businesscentral.dynamics.com/.default');

        ClientSecret := BCTenant.GetClientSecret();
        if not OAuth2.AcquireTokenWithClientCredentials(BCTenant."Client ID", ClientSecret, AccessTokenURL, '', Scopes, AuthToken) then
            Error(FailedToGetTokenErr, GetLastErrorText());

        CacheToken(CacheKey, AuthToken);
    end;

    local procedure TryGetCachedToken(CacheKey: Text; var AuthToken: SecretText): Boolean
    var
        ExpiresAt: DateTime;
    begin
        if not CachedTokens.ContainsKey(CacheKey) then
            exit(false);
        if not CachedTokenExpiry.Get(CacheKey, ExpiresAt) then
            exit(false);

        // Treat a token within the safety window of its expiry as already gone, so an
        // in-flight request never races the boundary on the server side.
        if CurrentDateTime() >= ExpiresAt then
            exit(false);

        AuthToken := CachedTokens.Get(CacheKey);
        exit(not AuthToken.IsEmpty());
    end;

    local procedure CacheToken(CacheKey: Text; AuthToken: SecretText)
    begin
        CachedTokens.Set(CacheKey, AuthToken);
        // Azure AD client-credential tokens are valid ~60-90 min. Cache for a conservative
        // 50-minute window so we always re-acquire comfortably before the real expiry.
        CachedTokenExpiry.Set(CacheKey, CurrentDateTime() + (50 * 60 * 1000));
    end;

    procedure GetAutomationApiOAuthToken(AADTenantId: Guid; ClientID: Text; ClientSecret: SecretText) AuthToken: SecretText
    var
        OAuth2: Codeunit OAuth2;
        FailedToGetTokenErr: Label 'Failed to get Automation API access token: %1', Comment = '%1 = Error message';
        Scopes: List of [Text];
        AADTenantIdText: Text;
        AccessTokenURL: Text;
    begin
        // Format AAD Tenant ID
        AADTenantIdText := Format(AADTenantId);
        AADTenantIdText := DelChr(AADTenantIdText, '=', '{}');

        AccessTokenURL := 'https://login.microsoftonline.com/' + AADTenantIdText + '/oauth2/v2.0/token';

        // Use standard BC API scope
        Scopes.Add('https://api.businesscentral.dynamics.com/.default');

        if not OAuth2.AcquireTokenWithClientCredentials(ClientID, ClientSecret, AccessTokenURL, '', Scopes, AuthToken) then
            Error(FailedToGetTokenErr, GetLastErrorText());
    end;

    local procedure ShowDebugMessage(ResponseText: Text; ActionName: Text)
    var
        BCSetup: Record "D4P BC Setup";
        DebugMsg: Label 'DEBUG - %1:\%2', Comment = '%1 = Label, %2 = Message body';
    begin
        if BCSetup.Get() then
            if BCSetup."Debug Mode" then
                Message(DebugMsg, ActionName, ResponseText);
    end;

    local procedure GetAdminAPIBaseUrl(): Text[250]
    var
        BCSetup: Record "D4P BC Setup";
    begin
        exit(BCSetup.GetAdminAPIBaseUrl());
    end;

    local procedure GetAutomationAPIBaseUrl(): Text[250]
    var
        BCSetup: Record "D4P BC Setup";
    begin
        exit(BCSetup.GetAutomationAPIBaseUrl());
    end;
}
