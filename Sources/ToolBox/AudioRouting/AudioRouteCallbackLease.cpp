#include "AudioRouteCallbackLease.hpp"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <new>
#include <thread>
#include <type_traits>
#include <vector>

namespace {
constexpr uint32_t kPermanentLeaseCapacity = 1 << 16;
using LeaseStorage = typename std::aligned_storage<
    sizeof(TBAudioCallbackLease), alignof(TBAudioCallbackLease)
>::type;
LeaseStorage permanentLeaseStorage[kPermanentLeaseCapacity];

class CallbackLeaseArena {
public:
    CallbackLeaseArena(LeaseStorage* storage, uint32_t capacity)
        : storage_(storage), capacity_(capacity), allocated_(capacity, false) {}

    TBAudioCallbackLease* Create(void* context) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        uint32_t slot;
        if (!freeSlots_.empty()) {
            slot = freeSlots_.back();
            freeSlots_.pop_back();
        } else {
            if (nextUnused_ >= capacity_) return nullptr;
            slot = nextUnused_++;
        }
        allocated_[slot] = true;
        inUse_ += 1;
        return new (&storage_[slot]) TBAudioCallbackLease(context);
    }

    bool Recycle(TBAudioCallbackLease* lease) noexcept {
        if (lease == nullptr || !lease->IsDetached() || lease->InFlight() != 0) return false;
        const uintptr_t start = reinterpret_cast<uintptr_t>(storage_);
        const uintptr_t address = reinterpret_cast<uintptr_t>(lease);
        const uintptr_t byteCount = sizeof(LeaseStorage) * capacity_;
        if (address < start || address >= start + byteCount) return false;
        const uintptr_t offset = address - start;
        if (offset % sizeof(LeaseStorage) != 0) return false;
        const uint32_t slot = static_cast<uint32_t>(offset / sizeof(LeaseStorage));

        std::lock_guard<std::mutex> lock(mutex_);
        if (!allocated_[slot]) return false;
        allocated_[slot] = false;
        lease->~TBAudioCallbackLease();
        freeSlots_.push_back(slot);
        inUse_ -= 1;
        return true;
    }

    uint32_t InUse() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return inUse_;
    }

private:
    LeaseStorage* storage_;
    uint32_t capacity_;
    uint32_t nextUnused_ = 0;
    uint32_t inUse_ = 0;
    std::vector<uint32_t> freeSlots_;
    std::vector<bool> allocated_;
    mutable std::mutex mutex_;
};

CallbackLeaseArena permanentLeaseArena(permanentLeaseStorage, kPermanentLeaseCapacity);
}

TBAudioCallbackLease* TBAudioCallbackLease::CreatePermanent(void* context) noexcept {
    return permanentLeaseArena.Create(context);
}

bool TBAudioCallbackLease::RecyclePermanentAfterCallbackSourceDestroyed(
    TBAudioCallbackLease* lease
) noexcept {
    return permanentLeaseArena.Recycle(lease);
}

uint32_t TBAudioCallbackLease::PermanentInUse() noexcept {
    return permanentLeaseArena.InUse();
}

void* TBAudioCallbackLease::Acquire() noexcept {
    uint64_t state = state_.load(std::memory_order_acquire);
    while ((state & kDetached) == 0) {
        if ((state & kReaderMask) == kReaderMask) return nullptr;
        if (state_.compare_exchange_weak(
                state, state + 1, std::memory_order_acq_rel, std::memory_order_acquire)) {
            return context_;
        }
    }
    return nullptr;
}

void TBAudioCallbackLease::Release() noexcept {
    state_.fetch_sub(1, std::memory_order_release);
}

void TBAudioCallbackLease::Detach() noexcept {
    state_.fetch_or(kDetached, std::memory_order_acq_rel);
}

bool TBAudioCallbackLease::IsDetached() const noexcept {
    return (state_.load(std::memory_order_acquire) & kDetached) != 0;
}

uint64_t TBAudioCallbackLease::InFlight() const noexcept {
    return state_.load(std::memory_order_acquire) & kReaderMask;
}

struct TBAudioCallbackLeaseTestState {
    int context = 1;
    TBAudioCallbackLease lease{&context};
};

TBAudioCallbackLeaseTestState* TBAudioCallbackLeaseTestCreate(void) {
    return new (std::nothrow) TBAudioCallbackLeaseTestState();
}

void TBAudioCallbackLeaseTestDestroy(TBAudioCallbackLeaseTestState* state) {
    delete state;
}

bool TBAudioCallbackLeaseTestAcquire(TBAudioCallbackLeaseTestState* state) {
    return state != nullptr && state->lease.Acquire() != nullptr;
}

void TBAudioCallbackLeaseTestRelease(TBAudioCallbackLeaseTestState* state) {
    if (state != nullptr) state->lease.Release();
}

void TBAudioCallbackLeaseTestDetach(TBAudioCallbackLeaseTestState* state) {
    if (state != nullptr) state->lease.Detach();
}

uint64_t TBAudioCallbackLeaseTestInFlight(const TBAudioCallbackLeaseTestState* state) {
    return state == nullptr ? 0 : state->lease.InFlight();
}

bool TBAudioCallbackLeaseTestRunDetachRace(uint32_t iterations) {
    if (iterations == 0) return true;
    std::atomic<TBAudioCallbackLease*> current{nullptr};
    std::atomic<uint32_t> phase{0};
    std::atomic<uint32_t> acquiredPhase{0};
    std::atomic<uint32_t> detachedPhase{0};
    std::atomic<bool> contextAlive{true};
    std::atomic<bool> valid{true};

    std::thread acquirer([&] {
        for (uint32_t expected = 1; expected <= iterations; ++expected) {
            while (phase.load(std::memory_order_acquire) < expected) std::this_thread::yield();
            TBAudioCallbackLease* lease = current.load(std::memory_order_acquire);
            void* context = lease->Acquire();
            if (context != nullptr) {
                if (!contextAlive.load(std::memory_order_acquire)) {
                    valid.store(false, std::memory_order_relaxed);
                }
                lease->Release();
            }
            acquiredPhase.store(expected, std::memory_order_release);
        }
    });
    std::thread detacher([&] {
        for (uint32_t expected = 1; expected <= iterations; ++expected) {
            while (phase.load(std::memory_order_acquire) < expected) std::this_thread::yield();
            TBAudioCallbackLease* lease = current.load(std::memory_order_acquire);
            lease->Detach();
            if (lease->InFlight() == 0) {
                contextAlive.store(false, std::memory_order_release);
            }
            detachedPhase.store(expected, std::memory_order_release);
        }
    });

    int context = 1;
    for (uint32_t iteration = 1; iteration <= iterations; ++iteration) {
        TBAudioCallbackLease lease(&context);
        contextAlive.store(true, std::memory_order_relaxed);
        current.store(&lease, std::memory_order_release);
        phase.store(iteration, std::memory_order_release);
        while (acquiredPhase.load(std::memory_order_acquire) < iteration
               || detachedPhase.load(std::memory_order_acquire) < iteration) {
            std::this_thread::yield();
        }
    }
    acquirer.join();
    detacher.join();
    return valid.load(std::memory_order_relaxed);
}

extern "C" bool TBAudioCallbackLeaseTestRunPermanentArenaReuse(
    uint32_t capacity,
    uint32_t iterations
) {
    if (capacity == 0 || iterations == 0) return false;
    std::vector<LeaseStorage> storage(capacity);
    CallbackLeaseArena arena(storage.data(), capacity);
    int context = 1;

    std::vector<TBAudioCallbackLease*> leases;
    leases.reserve(capacity);
    for (uint32_t index = 0; index < capacity; ++index) {
        TBAudioCallbackLease* lease = arena.Create(&context);
        if (lease == nullptr) return false;
        leases.push_back(lease);
    }
    if (arena.Create(&context) != nullptr) return false;
    for (TBAudioCallbackLease* lease : leases) {
        lease->Detach();
        if (!arena.Recycle(lease)) return false;
    }

    for (uint32_t iteration = 0; iteration < iterations; ++iteration) {
        TBAudioCallbackLease* lease = arena.Create(&context);
        if (lease == nullptr || lease->Acquire() == nullptr) return false;
        lease->Detach();
        if (arena.Recycle(lease)) return false;
        lease->Release();
        if (!arena.Recycle(lease)) return false;
    }
    return arena.InUse() == 0;
}
