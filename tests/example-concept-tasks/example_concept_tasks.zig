pub fn expectedMinutesInOven() u32 {
    return 40;
}

pub fn remainingMinutesInOven(elapsed: u32) u32 {
    return expectedMinutesInOven() - elapsed;
}

pub fn preparationTimeInMinutes(layers: u32) u32 {
    // Deliberately wrong, so that task 3 fails while tasks 1 and 2 pass.
    return layers * 3;
}
