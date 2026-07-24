#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
#include <atomic>

class TBAudioCallbackLease final {
public:
    explicit TBAudioCallbackLease(void* context) noexcept : context_(context) {}

    static TBAudioCallbackLease* CreatePermanent(void* context) noexcept;
    static bool RecyclePermanentAfterCallbackSourceDestroyed(
        TBAudioCallbackLease* lease
    ) noexcept;
    static uint32_t PermanentInUse() noexcept;

    void* Acquire() noexcept;
    void Release() noexcept;
    void Detach() noexcept;
    bool IsDetached() const noexcept;
    uint64_t InFlight() const noexcept;

private:
    static constexpr uint64_t kDetached = uint64_t{1} << 63;
    static constexpr uint64_t kReaderMask = ~kDetached;

    void* const context_;
    std::atomic<uint64_t> state_{0};
};

class TBAudioCallbackLeaseGuard final {
public:
    explicit TBAudioCallbackLeaseGuard(TBAudioCallbackLease* lease) noexcept : lease_(lease) {}
    ~TBAudioCallbackLeaseGuard() { lease_->Release(); }

    TBAudioCallbackLeaseGuard(const TBAudioCallbackLeaseGuard&) = delete;
    TBAudioCallbackLeaseGuard& operator=(const TBAudioCallbackLeaseGuard&) = delete;

private:
    TBAudioCallbackLease* lease_;
};
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TBAudioCallbackLeaseTestState TBAudioCallbackLeaseTestState;
TBAudioCallbackLeaseTestState* TBAudioCallbackLeaseTestCreate(void);
void TBAudioCallbackLeaseTestDestroy(TBAudioCallbackLeaseTestState* state);
bool TBAudioCallbackLeaseTestAcquire(TBAudioCallbackLeaseTestState* state);
void TBAudioCallbackLeaseTestRelease(TBAudioCallbackLeaseTestState* state);
void TBAudioCallbackLeaseTestDetach(TBAudioCallbackLeaseTestState* state);
uint64_t TBAudioCallbackLeaseTestInFlight(const TBAudioCallbackLeaseTestState* state);
bool TBAudioCallbackLeaseTestRunDetachRace(uint32_t iterations);

#ifdef __cplusplus
}
#endif
