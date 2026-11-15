//! The two Windows facilities the driver leans on: a job object that kills what it holds when the
//! driver goes away, and the machine-wide lock between runs.

use crate::{Error, Result};
use std::os::windows::io::{AsRawHandle, RawHandle};
use std::process::Child;
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, WAIT_ABANDONED, WAIT_OBJECT_0};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows_sys::Win32::System::Threading::{CreateMutexW, INFINITE, ReleaseMutex, WaitForSingleObject};

/// Windows ends every process of the job when the last handle to it closes, and that happens when
/// this driver dies too, however it dies. So a server never outlives the program that started it.
pub struct KillOnCloseJob(HANDLE);

impl KillOnCloseJob {
    pub fn new() -> Result<Self> {
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return Err(Error::new("Could not create the job object that ties the server to this program."));
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            if ok == 0 {
                CloseHandle(job);
                return Err(Error::new("Could not set up the job object that ties the server to this program."));
            }
            Ok(Self(job))
        }
    }

    pub fn add(&self, child: &Child) -> Result<()> {
        let process: RawHandle = child.as_raw_handle();
        if unsafe { AssignProcessToJobObject(self.0, process as HANDLE) } == 0 {
            return Err(Error::new("Could not put the server in the job object that ties it to this program."));
        }
        Ok(())
    }
}

impl Drop for KillOnCloseJob {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

/// One run at a time on this machine, and it is the same lock the PowerShell script took
/// (same name), so the two never overlap. Must be released on the thread that took it.
pub struct RunLock(HANDLE);

impl RunLock {
    pub fn acquire(name: &str) -> Result<Self> {
        let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        unsafe {
            let handle = CreateMutexW(std::ptr::null(), 0, wide.as_ptr());
            if handle.is_null() {
                return Err(Error::new("Could not create the lock that serialises runs."));
            }
            // A run killed while it held the lock leaves the mutex abandoned. The lock is ours all the same.
            match WaitForSingleObject(handle, INFINITE) {
                WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(Self(handle)),
                _ => {
                    CloseHandle(handle);
                    Err(Error::new("Could not wait for the lock that serialises runs."))
                }
            }
        }
    }
}

impl Drop for RunLock {
    fn drop(&mut self) {
        unsafe {
            ReleaseMutex(self.0);
            CloseHandle(self.0);
        }
    }
}
