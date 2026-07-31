#include "OCRRuntimeBridge.h"

#include <coreml_provider_factory.h>
#include <onnxruntime_cxx_api.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

struct TBOXORTSession {
    std::unique_ptr<Ort::Session> session;
    std::string inputName;
    std::string outputName;
};

namespace {
Ort::Env &SharedEnvironment() {
    static Ort::Env environment(ORT_LOGGING_LEVEL_WARNING, "ToolBox.PaddleOCR");
    return environment;
}

void SetError(char **destination, const char *message) {
    if (destination != nullptr) {
        *destination = strdup(message == nullptr ? "Unknown ONNX Runtime error" : message);
    }
}
}  // namespace

TBOXORTSession *TBOXORTCreateSession(
    const char *modelPath,
    bool useCoreML,
    char **errorMessage
) {
    if (modelPath == nullptr) {
        SetError(errorMessage, "Model path is missing");
        return nullptr;
    }
    try {
        Ort::SessionOptions options;
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        if (useCoreML) {
            Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CoreML(
                options,
                COREML_FLAG_ENABLE_ON_SUBGRAPH | COREML_FLAG_CREATE_MLPROGRAM
            ));
        }
        auto wrapper = std::make_unique<TBOXORTSession>();
        wrapper->session = std::make_unique<Ort::Session>(
            SharedEnvironment(),
            modelPath,
            options
        );
        Ort::AllocatorWithDefaultOptions allocator;
        auto input = wrapper->session->GetInputNameAllocated(0, allocator);
        auto output = wrapper->session->GetOutputNameAllocated(0, allocator);
        wrapper->inputName = input.get();
        wrapper->outputName = output.get();
        return wrapper.release();
    } catch (const Ort::Exception &error) {
        SetError(errorMessage, error.what());
    } catch (const std::exception &error) {
        SetError(errorMessage, error.what());
    }
    return nullptr;
}

bool TBOXORTRun(
    TBOXORTSession *session,
    const float *inputData,
    size_t inputCount,
    const int64_t *inputShape,
    size_t inputShapeCount,
    TBOXORTTensor *output,
    char **errorMessage
) {
    if (session == nullptr || inputData == nullptr || inputShape == nullptr || output == nullptr) {
        SetError(errorMessage, "Invalid inference arguments");
        return false;
    }
    output->data = nullptr;
    output->dataCount = 0;
    output->shape = nullptr;
    output->shapeCount = 0;
    try {
        auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        auto tensor = Ort::Value::CreateTensor<float>(
            memory,
            const_cast<float *>(inputData),
            inputCount,
            inputShape,
            inputShapeCount
        );
        const char *inputNames[] = {session->inputName.c_str()};
        const char *outputNames[] = {session->outputName.c_str()};
        auto outputs = session->session->Run(
            Ort::RunOptions{nullptr},
            inputNames,
            &tensor,
            1,
            outputNames,
            1
        );
        auto info = outputs[0].GetTensorTypeAndShapeInfo();
        const std::vector<int64_t> shape = info.GetShape();
        const size_t count = info.GetElementCount();
        const float *values = outputs[0].GetTensorData<float>();
        output->data = static_cast<float *>(malloc(count * sizeof(float)));
        output->shape = static_cast<int64_t *>(malloc(shape.size() * sizeof(int64_t)));
        if (output->data == nullptr || output->shape == nullptr) {
            TBOXORTFreeTensor(output);
            SetError(errorMessage, "Unable to allocate inference output");
            return false;
        }
        memcpy(output->data, values, count * sizeof(float));
        memcpy(output->shape, shape.data(), shape.size() * sizeof(int64_t));
        output->dataCount = count;
        output->shapeCount = shape.size();
        return true;
    } catch (const Ort::Exception &error) {
        SetError(errorMessage, error.what());
    } catch (const std::exception &error) {
        SetError(errorMessage, error.what());
    }
    TBOXORTFreeTensor(output);
    return false;
}

void TBOXORTDestroySession(TBOXORTSession *session) {
    delete session;
}

void TBOXORTFreeTensor(TBOXORTTensor *tensor) {
    if (tensor == nullptr) {
        return;
    }
    free(tensor->data);
    free(tensor->shape);
    tensor->data = nullptr;
    tensor->dataCount = 0;
    tensor->shape = nullptr;
    tensor->shapeCount = 0;
}

void TBOXORTFreeError(char *errorMessage) {
    free(errorMessage);
}
