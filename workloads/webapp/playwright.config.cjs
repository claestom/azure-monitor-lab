const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 45000,
  workers: 1,
  reporter: 'list',
  use: {
    baseURL: 'http://127.0.0.1:5188',
    browserName: 'chromium',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure'
  },
  webServer: {
    command: 'dotnet run --project AmlabHello.csproj --no-launch-profile --urls http://127.0.0.1:5188',
    url: 'http://127.0.0.1:5188/healthz',
    reuseExistingServer: false,
    timeout: 120000,
    env: { ASPNETCORE_ENVIRONMENT: 'Production', APPLICATIONINSIGHTS_CONNECTION_STRING: '', LabConsole__Foundry__Enabled: 'false', LabConsole__Sre__Enabled: 'false', LabConsole__Health__Enabled: 'false', LabConsole__Operations__Enabled: 'false' }
  }
});