using System.Text.Json;
using Microsoft.AspNetCore.SignalR;
using TranscriptionServer.Hubs;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSignalR();
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
        policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
});

var app = builder.Build();

app.UseCors();

app.MapHub<TranscriptionHub>("/hubs/transcription");

app.MapPost("/api/chunks", async (
    HttpRequest request,
    IHubContext<TranscriptionHub> hubContext,
    IConfiguration configuration) =>
{
    string? apiKey = request.Headers["X-Api-Key"];
    string? expectedKey = configuration["ChunkApiKey"];
    if (string.IsNullOrEmpty(expectedKey) || apiKey != expectedKey)
    {
        return Results.Unauthorized();
    }

    ChunkPayload? chunk;
    try
    {
        chunk = await request.ReadFromJsonAsync<ChunkPayload>();
    }
    catch (JsonException)
    {
        return Results.BadRequest();
    }

    if (chunk is null || string.IsNullOrEmpty(chunk.CallId))
    {
        return Results.BadRequest();
    }

    await hubContext.Clients.All.SendAsync("TranscriptionChunk", chunk);
    return Results.Ok();
});

app.Run();

public record ChunkPayload(string UserId, string CustomerId, string CallId, string TranscriptionChunk);
