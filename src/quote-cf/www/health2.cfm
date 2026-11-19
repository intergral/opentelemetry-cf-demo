<cftry>
    <cfquery name="healthCheck" datasource="mysql">
        SELECT COUNT(*) as customer_count FROM customers
    </cfquery>

    <cfset status = "healthy">
    <cfset message = "Database connection OK">

    <cfcatch type="any">
        <cfheader statuscode="503" statustext="Service Unavailable">
        <cfset status = "unhealthy">
        <cfset message = "database_error: " & cfcatch.message>
    </cfcatch>
</cftry>

<cfif status EQ "unhealthy">
    <cfheader statuscode="503" statustext="Service Unavailable">
</cfif>

<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>QuoteCF Health</title>
    <style>
        body { font-family: sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f4f4f4; }
        .card { background: white; border-radius: 8px; padding: 40px 60px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        .indicator { width: 80px; height: 80px; border-radius: 50%; margin: 0 auto 20px; }
        .healthy { background: #22c55e; }
        .unhealthy { background: #ef4444; }
        h1 { margin: 0 0 8px; font-size: 1.5rem; }
        p { color: #666; margin: 0; }
    </style>
</head>
<body>
    <div class="card">
        <cfoutput>
            <div class="indicator #status#"></div>
            <h1>#status#</h1>
            <p>#message#</p>
        </cfoutput>
    </div>
</body>
</html>
