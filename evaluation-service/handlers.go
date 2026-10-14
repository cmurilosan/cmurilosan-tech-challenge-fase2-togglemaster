package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"
)

type EvaluationResponse struct {
	FlagName string `json:"flag_name"`
	UserID   string `json:"user_id"`
	Result   bool   `json:"result"`
}

// healthHandler serve de liveness probe: confirma apenas que o processo
// responde. Nao toca em dependencia externa de proposito -- restart nao
// resolve Redis fora do ar e derrubaria todas as replicas de uma vez.
func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// readyHandler serve de readiness probe. Checa so o Redis, que e a dependencia
// propria deste servico. O flag-service e o targeting-service ficam de fora de
// proposito: encadear readiness em dependencia de servico multiplica as
// indisponibilidades e uma falha neles tiraria este pod do ar junto.
func (a *App) readyHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	reqCtx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	if err := a.RedisClient.Ping(reqCtx).Err(); err != nil {
		log.Printf("Readiness falhou: %v", err)
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{
			"status": "not ready",
			"reason": "redis indisponivel",
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
}

func (a *App) evaluationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// 1. Parsear os query parameters
	userID := r.URL.Query().Get("user_id")
	flagName := r.URL.Query().Get("flag_name")

	if userID == "" || flagName == "" {
		http.Error(w, `{"error": "user_id e flag_name são obrigatórios"}`, http.StatusBadRequest)
		return
	}

	// 2. Obter a decisão (lógica de cache/serviço está em evaluator.go)
	result, err := a.getDecision(userID, flagName)
	if err != nil {
		// Se o erro for "não encontrado", retornamos 'false' (comportamento seguro)
		if _, ok := err.(*NotFoundError); ok {
			result = false
		} else {
			// Outros erros (serviços offline, etc)
			log.Printf("Erro ao avaliar flag '%s': %v", flagName, err)
			http.Error(w, `{"error": "Erro interno ao avaliar a flag"}`, http.StatusBadGateway)
			return
		}
	}

	// 3. Enviar evento para SQS (assincronamente)
	// Isso não bloqueia a resposta para o cliente.
	go a.sendEvaluationEvent(userID, flagName, result)

	// 4. Retornar a resposta
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(EvaluationResponse{
		FlagName: flagName,
		UserID:   userID,
		Result:   result,
	})
}