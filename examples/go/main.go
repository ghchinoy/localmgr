// Command gateway-example demonstrates querying LocalMgr's OpenAI-compatible
// API Gateway (http://127.0.0.1:4891) from Go using only the standard library.
//
// It exercises:
//  1. GET /v1/stats  (gateway health and active runner status)
//  2. GET /v1/models (vault model catalog discovery)
//  3. POST /v1/chat/completions (buffered completion + Gemma 4 reasoning trace)
//  4. POST /v1/chat/completions with "stream": true (incremental SSE streaming)
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"
)

type statsResponse struct {
	Status               string `json:"status"`
	TotalGatewayRequests int    `json:"total_gateway_requests"`
	ActiveRunner         struct {
		Status string `json:"status"`
		Model  string `json:"model"`
	} `json:"active_runner"`
}

type modelEntry struct {
	ID     string `json:"id"`
	Active bool   `json:"active"`
}

type modelsResponse struct {
	Data []modelEntry `json:"data"`
}

type chatMessage struct {
	Role             string `json:"role"`
	Content          string `json:"content"`
	ReasoningContent string `json:"reasoning_content,omitempty"` // llama-server (GGUF)
	Reasoning        string `json:"reasoning,omitempty"`         // mlx_lm.server (MLX 0.32.2+)
}

func (m chatMessage) thinkingText() string {
	if strings.TrimSpace(m.ReasoningContent) != "" {
		return m.ReasoningContent
	}
	return m.Reasoning
}

type chatRequest struct {
	Model     string        `json:"model"`
	Messages  []chatMessage `json:"messages"`
	MaxTokens int           `json:"max_tokens"`
	Stream    bool          `json:"stream"`
}

type chatResponse struct {
	Model   string `json:"model"`
	Choices []struct {
		Message      chatMessage `json:"message"`
		FinishReason string      `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		TotalTokens      int `json:"total_tokens"`
	} `json:"usage"`
}

type sseChunk struct {
	Choices []struct {
		Delta chatMessage `json:"delta"`
	} `json:"choices"`
}

var preferredModels = []string{
	"gemma-4-E2B-it-Q4_K_M",
	"mlx-gemma-4-e2b",
	"gemma-4-E4B-it-Q4_K_M",
	"mlx-gemma-4-e4b",
	"mlx-gemma-4-12b-it",
}

func main() {
	baseURL := flag.String("base-url", "http://127.0.0.1:4891", "LocalMgr gateway base URL")
	modelFlag := flag.String("model", "", "Model ID from /v1/models (defaults to active runner or mlx-gemma-4-e2b)")
	promptFlag := flag.String("prompt", "Explain Apple Silicon zero-copy unified memory in one concise sentence.", "Prompt to send")
	maxTokens := flag.Int("max-tokens", 512, "Max completion tokens (use >= 512 for Gemma 4 thinking models)")
	streamOnly := flag.Bool("stream", false, "Run only the streaming SSE completion")
	flag.Parse()

	base := strings.TrimRight(*baseURL, "/")
	client := &http.Client{Timeout: 5 * time.Minute}

	stats, err := fetchStats(client, base)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Could not reach LocalMgr gateway at %s: %v\nHint: Launch LocalMgr (`open /Applications/LocalMgr.app`) first.\n", base, err)
		os.Exit(1)
	}

	models, err := fetchModels(client, base)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to query /v1/models: %v\n", err)
		os.Exit(1)
	}

	activeModel := stats.ActiveRunner.Model
	if activeModel == "" {
		activeModel = "None (will wake on demand)"
	}
	fmt.Printf("Gateway Status: %s | Runner Status: %s | Active Model: %s\n",
		stats.Status, stats.ActiveRunner.Status, activeModel)

	var ids []string
	for _, m := range models.Data {
		ids = append(ids, m.ID)
	}
	fmt.Printf("Discovered Vault Models (%d): %s\n", len(ids), strings.Join(ids, ", "))

	targetModel := selectModel(models.Data, *modelFlag)

	ctx := context.Background()
	if *streamOnly {
		if err := runStreamingCompletion(ctx, client, base, targetModel, *promptFlag, *maxTokens); err != nil {
			fmt.Fprintf(os.Stderr, "Streaming completion failed: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if err := runBufferedCompletion(ctx, client, base, targetModel, *promptFlag, *maxTokens); err != nil {
		fmt.Fprintf(os.Stderr, "Buffered completion failed: %v\n", err)
		os.Exit(1)
	}
	if err := runStreamingCompletion(ctx, client, base, targetModel, *promptFlag, *maxTokens); err != nil {
		fmt.Fprintf(os.Stderr, "Streaming completion failed: %v\n", err)
		os.Exit(1)
	}
}

func fetchStats(client *http.Client, base string) (*statsResponse, error) {
	resp, err := client.Get(base + "/v1/stats")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out statsResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

func fetchModels(client *http.Client, base string) (*modelsResponse, error) {
	resp, err := client.Get(base + "/v1/models")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out modelsResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

func selectModel(entries []modelEntry, requested string) string {
	if requested != "" {
		return requested
	}
	for _, e := range entries {
		if e.Active && e.ID != "" {
			return e.ID
		}
	}
	var ids []string
	for _, e := range entries {
		ids = append(ids, e.ID)
	}
	for _, pref := range preferredModels {
		if slices.Contains(ids, pref) {
			return pref
		}
	}
	if len(ids) > 0 {
		return ids[0]
	}
	return "default"
}

func runBufferedCompletion(ctx context.Context, client *http.Client, base, model, prompt string, maxTokens int) error {
	fmt.Printf("\n--- 1. Buffered Chat Completion (model=%q) ---\n", model)
	reqBody := chatRequest{
		Model: model,
		Messages: []chatMessage{
			{Role: "system", Content: "You are a concise technical assistant."},
			{Role: "user", Content: prompt},
		},
		MaxTokens: maxTokens,
		Stream:    false,
	}
	payload, err := json.Marshal(reqBody)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var parsed chatResponse
	if err := json.Unmarshal(bodyBytes, &parsed); err != nil {
		return err
	}
	if len(parsed.Choices) == 0 {
		return fmt.Errorf("no choices returned: %s", string(bodyBytes))
	}

	msg := parsed.Choices[0].Message
	if thinking := strings.TrimSpace(msg.thinkingText()); thinking != "" {
		fmt.Printf("[Reasoning Trace]:\n%s\n\n", thinking)
	}
	fmt.Printf("[Assistant Answer]:\n%s\n", strings.TrimSpace(msg.Content))
	fmt.Printf("\n[Usage]: prompt_tokens=%d, completion_tokens=%d, total_tokens=%d\n",
		parsed.Usage.PromptTokens, parsed.Usage.CompletionTokens, parsed.Usage.TotalTokens)
	return nil
}

func runStreamingCompletion(ctx context.Context, client *http.Client, base, model, prompt string, maxTokens int) error {
	fmt.Printf("\n--- 2. Streaming SSE Chat Completion (model=%q) ---\n", model)
	reqBody := chatRequest{
		Model: model,
		Messages: []chatMessage{
			{Role: "system", Content: "You are a concise technical assistant."},
			{Role: "user", Content: prompt},
		},
		MaxTokens: maxTokens,
		Stream:    true,
	}
	payload, err := json.Marshal(reqBody)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBytes, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(errBytes))
	}

	scanner := bufio.NewScanner(resp.Body)
	inThinking := false
	inAnswer := false

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		dataStr := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if dataStr == "[DONE]" {
			break
		}
		var chunk sseChunk
		if err := json.Unmarshal([]byte(dataStr), &chunk); err != nil || len(chunk.Choices) == 0 {
			continue
		}
		delta := chunk.Choices[0].Delta
		if thinking := delta.thinkingText(); thinking != "" {
			if !inThinking {
				fmt.Print("[Thinking]: ")
				inThinking = true
			}
			fmt.Print(thinking)
		}
		if delta.Content != "" {
			if !inAnswer {
				if inThinking {
					fmt.Print("\n\n")
				}
				fmt.Print("[Answer]: ")
				inAnswer = true
			}
			fmt.Print(delta.Content)
		}
	}
	fmt.Println()
	return scanner.Err()
}
