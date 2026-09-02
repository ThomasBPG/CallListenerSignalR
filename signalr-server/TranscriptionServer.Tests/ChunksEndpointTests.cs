using System.Net;
using System.Net.Http.Json;
using System.Text;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

public class ChunksEndpointTests
{
    private static readonly object ValidPayload = new
    {
        userId = "u1",
        customerId = "c1",
        callId = "call1",
        transcriptionChunk = "hello"
    };

    private static WebApplicationFactory<Program> CreateFactory(string apiKey = "test-key")
    {
        return new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.UseSetting("ChunkApiKey", apiKey);
        });
    }

    [Fact]
    public async Task PostChunk_WithoutApiKey_Returns401()
    {
        var client = CreateFactory().CreateClient();

        var response = await client.PostAsJsonAsync("/api/chunks", ValidPayload);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task PostChunk_WithWrongApiKey_Returns401()
    {
        var client = CreateFactory().CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "wrong-key");

        var response = await client.PostAsJsonAsync("/api/chunks", ValidPayload);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task PostChunk_WithMalformedBody_Returns400()
    {
        var client = CreateFactory().CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "test-key");

        var response = await client.PostAsync(
            "/api/chunks",
            new StringContent("not json", Encoding.UTF8, "application/json"));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task PostChunk_WithValidRequestAndApiKey_Returns200()
    {
        var client = CreateFactory().CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "test-key");

        var response = await client.PostAsJsonAsync("/api/chunks", ValidPayload);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
