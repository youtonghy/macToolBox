#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TBOXORTSession TBOXORTSession;

typedef struct {
    float *data;
    size_t dataCount;
    int64_t *shape;
    size_t shapeCount;
} TBOXORTTensor;

TBOXORTSession *TBOXORTCreateSession(
    const char *modelPath,
    bool useCoreML,
    char **errorMessage
);

bool TBOXORTRun(
    TBOXORTSession *session,
    const float *inputData,
    size_t inputCount,
    const int64_t *inputShape,
    size_t inputShapeCount,
    TBOXORTTensor *output,
    char **errorMessage
);

void TBOXORTDestroySession(TBOXORTSession *session);
void TBOXORTFreeTensor(TBOXORTTensor *tensor);
void TBOXORTFreeError(char *errorMessage);

#ifdef __cplusplus
}
#endif
